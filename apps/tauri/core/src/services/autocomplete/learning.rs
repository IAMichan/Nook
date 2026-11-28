//! Learning from what the user writes: writing samples, frequently repeated phrases, and sealing on disk so a copy of
//! the folder reads as noise without the system credential vault. Ported from `CompletionLearning.swift` and
//! `CompletionSealing.swift` (SV-62).

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};

use base64::Engine;
use chacha20poly1305::aead::{Aead, Generate, KeyInit};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use unicode_normalization::char::canonical_combining_class;

use super::{privacy, stats};
use crate::brain::memory::text as memory_text;
use crate::paths;
use crate::secrets::SecretStore;
use crate::services::attention;

/// One sample of text written by the user, with the app it was written in, when, and optional sorted context words.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Sample {
    pub app: String,
    pub text: String,
    pub date: DateTime<Utc>,
    /// The words of what was around the field when this was written (conversation, mail, window title): enough to match
    /// earlier writing about the same subject without keeping what others wrote verbatim.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context: Option<String>,
}

/// What the user wrote, so suggestions sound like them. Stored locally, secrets taken out first, deletable in Settings.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct CompletionSamples {
    pub samples: Vec<Sample>,
    pub capacity: usize,
    pub max_length: usize,
    /// Short chat messages ("Thanks, see you tomorrow!") count too: they hold the phrases written most often.
    pub min_length: usize,
    /// Shorter samples teach phrases (see [`CompletionPhrases`]) but say little about style in the prompt.
    pub min_prompt_length: usize,
}

impl Default for CompletionSamples {
    fn default() -> Self {
        Self { samples: Vec::new(), capacity: 800, max_length: 2_000, min_length: 12, min_prompt_length: 40 }
    }
}

impl CompletionSamples {
    /// Words a sample from another app must share with the topic to be shown as the user's writing.
    pub const SHARED_WORDS_FROM_OTHER_APPS: usize = 2;
    /// The end of the context [`Self::context_words`] reads.
    pub const CONTEXT_LENGTH: usize = 600;

    pub fn len(&self) -> usize {
        self.samples.len()
    }

    pub fn is_empty(&self) -> bool {
        self.samples.is_empty()
    }

    /// Text that only extends the last sample of the same app (still typing in that field) replaces it.
    pub fn add(&mut self, text: &str, app: &str, context: Option<String>, date: DateTime<Utc>) {
        let trimmed_all = text.trim();
        let trimmed: String = suffix_chars(trimmed_all, self.max_length);
        if trimmed.chars().count() < self.min_length {
            return;
        }
        let context = context.filter(|c| !c.is_empty());
        if let Some(index) = self.samples.iter().rposition(|s| s.app == app) {
            let existing = &self.samples[index];
            if trimmed.starts_with(&existing.text) || existing.text.starts_with(&trimmed) {
                if trimmed.chars().count() >= existing.text.chars().count() {
                    let kept_context = context.or_else(|| existing.context.clone());
                    self.samples[index] = Sample { app: app.to_string(), text: trimmed, date, context: kept_context };
                }
                return;
            }
        }
        self.samples.push(Sample { app: app.to_string(), text: trimmed, date, context });
        if self.samples.len() > self.capacity {
            let excess = self.samples.len() - self.capacity;
            self.samples.drain(..excess);
        }
    }

    pub fn remove_all(&mut self) {
        self.samples.clear();
    }

    /// Removes one sample (as deleted in Settings). Returns true if it was found and removed.
    pub fn remove(&mut self, sample: &Sample) -> bool {
        if let Some(index) = self.samples.iter().position(|s| s == sample) {
            self.samples.remove(index);
            true
        } else {
            false
        }
    }

    /// The samples that show best how the user writes here: the ones about the same thing as `topic` first, then this
    /// app's newest. Another app's writing only comes along when it shares words with the topic. A sample the text in
    /// the field already holds (`excluding`) is left out: the model would copy it.
    pub fn relevant(&self, app: &str, topic: &str, excluding: &str, limit: usize) -> Vec<String> {
        let wanted = memory_text::tokens(topic);
        let field = excluding.to_lowercase();
        let mut scored: Vec<(f64, usize)> = Vec::new();
        for (index, sample) in self.samples.iter().enumerate() {
            if sample.text.chars().count() < self.min_prompt_length {
                continue;
            }
            if !field.is_empty() {
                let prefix: String = sample.text.chars().take(80).collect::<String>().to_lowercase();
                if field.contains(&prefix) {
                    continue;
                }
            }
            let shared = if wanted.is_empty() {
                0
            } else {
                let mut words = memory_text::tokens(&sample.text);
                if let Some(ctx) = &sample.context {
                    for w in ctx.split(' ').filter(|w| !w.is_empty()) {
                        words.insert(w.to_string());
                    }
                }
                words.intersection(&wanted).count()
            };
            let same_app = sample.app == app;
            if !same_app && shared < Self::SHARED_WORDS_FROM_OTHER_APPS {
                continue;
            }
            // Newer writing breaks a tie: 0 for the oldest, up to 1 for the newest.
            let recency = (index + 1) as f64 / self.samples.len() as f64;
            let score = shared.min(6) as f64 + if same_app { 1.5 } else { 0.0 } + recency;
            scored.push((score, index));
        }
        scored.sort_by(|a, b| b.0.total_cmp(&a.0).then_with(|| b.1.cmp(&a.1)));
        scored.into_iter().take(limit).map(|(_, idx)| self.samples[idx].text.clone()).collect()
    }

    /// The words of the context a text was written in (topic without the text itself), for `Sample.context`: the newest
    /// end of it, secrets taken out first, as the sorted set of words `memory_text::tokens` finds.
    pub fn context_words(topic: &str, limit: usize) -> Option<String> {
        let tail = suffix_chars(topic, Self::CONTEXT_LENGTH);
        let clean = privacy::sanitize(&tail);
        let words: Vec<String> = memory_text::tokens(&clean).into_iter().take(limit).collect();
        if words.is_empty() {
            None
        } else {
            Some(words.join(" "))
        }
    }

    /// What the user typed in a field since it got the focus: the stretch between what stayed the same at the start and
    /// at the end, from `start` (the text when the field was first seen) to `now`. `None` when nothing was added. Text
    /// that was there already (a quoted mail, a document opened to edit) is left out.
    pub fn typed(from: &str, to: &str) -> Option<String> {
        let old: Vec<char> = from.chars().collect();
        let new: Vec<char> = to.chars().collect();
        let mut prefix = 0;
        while prefix < old.len() && prefix < new.len() && old[prefix] == new[prefix] {
            prefix += 1;
        }
        let mut suffix = 0;
        while suffix < old.len() - prefix && suffix < new.len() - prefix && old[old.len() - 1 - suffix] == new[new.len() - 1 - suffix] {
            suffix += 1;
        }
        if new.len() - suffix <= prefix {
            return None;
        }
        // Start the stretch at the beginning of the word the change began in: "Hoi Jan" typed after "Ho" is "Hoi Jan".
        let mut start_idx = prefix;
        while start_idx > 0 && !new[start_idx - 1].is_whitespace() {
            start_idx -= 1;
        }
        Some(new[start_idx..(new.len() - suffix)].iter().collect())
    }

    /// Words the user writes often, weighted 0..=1. Short common words are left out: the model knows those.
    pub fn vocabulary(&self, limit: usize) -> BTreeMap<String, f64> {
        let mut counts: HashMap<String, usize> = HashMap::new();
        for sample in &self.samples {
            for word in sample.text.split(|c: char| !(c.is_alphabetic() || c == '\'' || c == '’')) {
                if word.chars().count() >= 4 {
                    *counts.entry(word.to_string()).or_insert(0) += 1;
                }
            }
        }
        let mut frequent: Vec<(String, usize)> = counts.into_iter().filter(|(_, c)| *c >= 2).collect();
        frequent.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
        frequent.truncate(limit);
        let Some(top) = frequent.first().map(|(_, c)| *c) else {
            return BTreeMap::new();
        };
        let scale = ((top + 1) as f64).ln();
        frequent.into_iter().map(|(word, count)| (word, ((count + 1) as f64).ln() / scale)).collect()
    }
}

/// The phrases the user writes again and again, learned from their own writing ([`CompletionSamples`]): after
/// "met vriendelijke" comes "groet", after "ik hoop dat" comes "het goed met je gaat". It counts which word follows the
/// one to three words before it, newer writing counting more, and suggests the words that nearly always follow at once,
/// without waiting for the model. A phrase turned down with Escape counts less from then on.
#[derive(Debug, Clone, Default)]
pub struct CompletionPhrases {
    /// The words before (up to `ORDER`, normalized, joined by spaces) -> the word that came next, as written -> weight.
    next: HashMap<String, HashMap<String, f64>>,
    /// `rejection_key` -> times turned down.
    rejected: HashMap<String, u32>,
}

impl CompletionPhrases {
    /// Words before the next one that are looked at.
    pub const ORDER: usize = 3;
    /// Words before a turned-down word that its rejection is kept for.
    pub const REJECTION_CONTEXT: usize = 2;
    /// Writing this old counts half (60 days, in seconds).
    pub const HALF_LIFE: f64 = 60.0 * 24.0 * 3600.0;
    /// What one rejection takes off a word's weight (a fresh occurrence weighs 1).
    pub const REJECTION_WEIGHT: f64 = 2.0;

    pub fn from_samples(samples: &[Sample], rejected: HashMap<String, u32>, now: DateTime<Utc>) -> Self {
        let mut next: HashMap<String, HashMap<String, f64>> = HashMap::new();
        for sample in samples {
            let elapsed = (now - sample.date).num_milliseconds() as f64 / 1000.0;
            let weight = attention::decay(1.0, elapsed, Self::HALF_LIFE);
            // Suggestions stay on one line: phrases are learned within a line.
            for line in sample.text.split(['\n', '\r']) {
                let words: Vec<&str> = line.split_whitespace().collect();
                if words.len() < 2 {
                    continue;
                }
                let keys: Vec<String> = words.iter().map(|w| Self::normalized(w)).collect();
                for index in 1..words.len() {
                    if keys[index].is_empty() {
                        continue;
                    }
                    let max_len = Self::ORDER.min(index);
                    for length in 1..=max_len {
                        let context = &keys[(index - length)..index];
                        // A dash or a lone symbol breaks the phrase.
                        if context.iter().any(|k| k.is_empty()) {
                            break;
                        }
                        *next.entry(context.join(" ")).or_default().entry(words[index].to_string()).or_insert(0.0) += weight;
                    }
                }
            }
        }
        Self { next, rejected }
    }

    pub fn is_empty(&self) -> bool {
        self.next.is_empty()
    }

    pub fn reject(&mut self, key: &str) {
        if !key.is_empty() {
            *self.rejected.entry(key.to_string()).or_insert(0) += 1;
        }
    }

    /// How the text before the cursor goes on, as far as the user's own phrases are sure of it: the rest of the word
    /// being typed, then whole words, up to the end of a sentence. Starts with a space when it starts a new word.
    /// `None` when no phrase fits well enough.
    pub fn predict(&self, before: &str, max_words: usize) -> Option<String> {
        if max_words == 0 || self.next.is_empty() {
            return None;
        }
        let (mut context, mut partial) = Self::split(before);
        let mut result = String::new();
        let mut count = 0;
        while count < max_words {
            let Some(word) = self.choose(&context, &partial, count == 0) else {
                break;
            };
            if partial.is_empty() {
                result.push(' ');
                result.push_str(&word);
            } else {
                let skip = partial.chars().count();
                result.extend(word.chars().skip(skip));
            }
            partial.clear();
            context.push(Self::normalized(&word));
            count += 1;
            if word.chars().last().is_some_and(|c| matches!(c, '.' | '!' | '?')) {
                break;
            }
        }
        if result.is_empty() {
            None
        } else {
            Some(result)
        }
    }

    /// Identifies the first word of a learned suggestion after `before`, to count less once it is turned down.
    pub fn rejection_key(before: &str, suggestion: &str) -> Option<String> {
        let (context, partial) = Self::split(before);
        let rest = if partial.is_empty() { suggestion.trim_start() } else { suggestion };
        let first_part: String = rest.chars().take_while(|c| !c.is_whitespace()).collect();
        let word = Self::normalized(&format!("{partial}{first_part}"));
        if context.is_empty() || word.is_empty() {
            return None;
        }
        let start = context.len().saturating_sub(Self::REJECTION_CONTEXT);
        Some(format!("{}|{word}", context[start..].join(" ")))
    }

    /// The phrases written most often, for the prompt: three words or more, the last one nearly always following the
    /// others.
    pub fn frequent(&self, limit: usize) -> Vec<String> {
        let mut found: Vec<(f64, String)> = Vec::new();
        for (context, followers) in &self.next {
            if !context.contains(' ') {
                continue;
            }
            let total: f64 = followers.values().sum();
            let Some((best_word, best_weight)) = followers.iter().max_by(|a, b| a.1.total_cmp(b.1).then_with(|| b.0.cmp(a.0))) else {
                continue;
            };
            if *best_weight >= 3.0 && (*best_weight / total) >= 0.6 {
                found.push((*best_weight, format!("{context} {best_word}")));
            }
        }
        found.sort_by(|a, b| b.0.total_cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
        let mut result: Vec<(String, String)> = Vec::new();
        for (_, phrase) in found {
            if result.len() >= limit {
                break;
            }
            let words = phrase.split(' ').map(Self::normalized).collect::<Vec<_>>().join(" ");
            // Not the same phrase again, one word shorter or longer.
            if result.iter().any(|(_, existing)| existing.contains(&words) || words.contains(existing)) {
                continue;
            }
            result.push((phrase, words));
        }
        result.into_iter().map(|(phrase, _)| phrase).collect()
    }

    fn choose(&self, context: &[String], partial: &str, penalized: bool) -> Option<String> {
        let typed = partial.to_lowercase();
        let partial_len = partial.chars().count();
        let recent_start = context.len().saturating_sub(Self::REJECTION_CONTEXT);
        let recent = context[recent_start..].join(" ");

        let max_len = Self::ORDER.min(context.len());
        for length in (1..=max_len).rev() {
            let key = &context[(context.len() - length)..];
            if key.iter().any(|k| k.is_empty()) {
                continue;
            }
            // One word says too little to start a suggestion on its own: after "Hoi" the user wrote "Lisa" often, but
            // that says nothing about who this message is for. Once they start typing the word ("Hoi L"), or the phrase
            // is under way, it does.
            if length == 1 && penalized && partial.is_empty() {
                continue;
            }
            let Some(followers) = self.next.get(&key.join(" ")) else {
                continue;
            };
            // Grouped by the word itself; the form written most often is the one typed.
            let mut totals: HashMap<String, f64> = HashMap::new();
            let mut forms: HashMap<String, (f64, String)> = HashMap::new();
            for (word, &weight) in followers {
                if word.chars().count() <= partial_len || !word.to_lowercase().starts_with(&typed) {
                    continue;
                }
                let normal = Self::normalized(word);
                *totals.entry(normal.clone()).or_insert(0.0) += weight;
                let replace = match forms.get(&normal) {
                    Some((existing_weight, existing_word)) => {
                        weight > *existing_weight || (weight == *existing_weight && word < existing_word)
                    }
                    None => true,
                };
                if replace {
                    forms.insert(normal, (weight, word.clone()));
                }
            }
            let total: f64 = totals.values().sum();
            let (minimum, share) = if length == 1 { (4.0, 0.75) } else { (2.5, 0.6) };
            // Too little writing after these words to tell: fewer words before may know.
            if total < minimum {
                continue;
            }
            let best = totals
                .into_iter()
                .map(|(normal, val)| {
                    let penalty = if penalized {
                        let rk = format!("{recent}|{normal}");
                        self.rejected.get(&rk).copied().unwrap_or(0) as f64 * Self::REJECTION_WEIGHT
                    } else {
                        0.0
                    };
                    (val - penalty, normal)
                })
                .max_by(|a, b| a.0.total_cmp(&b.0).then_with(|| b.1.cmp(&a.1)));
            let (best_score, best_normal) = best?;
            if best_score >= minimum && best_score / total >= share {
                return forms.get(&best_normal).map(|(_, w)| w.clone());
            }
            return None;
        }
        None
    }

    /// The words of the line the cursor is on, normalized, and the word the cursor is in (empty after a space). A word
    /// that ends in punctuation ("groet,") is finished: the next one starts after a space.
    fn split(before: &str) -> (Vec<String>, String) {
        let line = before.split('\n').next_back().unwrap_or("").trim_end_matches('\r');
        let mut words: Vec<&str> = line.split_whitespace().collect();
        let mut partial = String::new();
        if let Some(last) = line.chars().last() {
            if !last.is_whitespace() {
                if let Some(word) = words.pop() {
                    if last.is_alphanumeric() {
                        partial = word.to_string();
                    } else {
                        words.push(word);
                    }
                }
            }
        }
        (words.into_iter().map(Self::normalized).collect(), partial)
    }

    /// Lowercased, without punctuation or symbols around it: "Groet," and "groet" are the same word.
    pub fn normalized(word: &str) -> String {
        word.to_lowercase().trim_matches(|c: char| !c.is_alphanumeric() && canonical_combining_class(c) == 0).to_string()
    }
}

fn suffix_chars(text: &str, max: usize) -> String {
    let count = text.chars().count();
    if count <= max {
        text.to_string()
    } else {
        text.chars().skip(count - max).collect()
    }
}

// ---------------------------------------------------------------------------
// Sealing (encrypted at rest with a key in the system credential store)
// ---------------------------------------------------------------------------

/// Starts every sealed file, so an older plain file is told apart (and sealed at the next save).
pub const SEAL_MAGIC: &[u8] = b"NOOKSEAL1";
/// The key's account in the credential vault (`SecretStore`).
pub const SEAL_KEY_ACCOUNT: &str = "autocomplete.samplesKey";

pub fn is_sealed(data: &[u8]) -> bool {
    data.starts_with(SEAL_MAGIC)
}

/// Seals `data` with ChaCha20-Poly1305: `NOOKSEAL1 || nonce(12) || ciphertext+tag`.
pub fn seal(data: &[u8], key: &[u8; 32]) -> Result<Vec<u8>, String> {
    let cipher = ChaCha20Poly1305::new(&Key::from(*key));
    let nonce = <[u8; 12]>::generate();
    let ciphertext = cipher.encrypt(&Nonce::from(nonce), data).map_err(|e| e.to_string())?;
    let mut out = Vec::with_capacity(SEAL_MAGIC.len() + 12 + ciphertext.len());
    out.extend_from_slice(SEAL_MAGIC);
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&ciphertext);
    Ok(out)
}

/// Opens a sealed buffer, or `None` when the key does not match or the data is damaged.
pub fn open(data: &[u8], key: &[u8; 32]) -> Option<Vec<u8>> {
    let body = data.strip_prefix(SEAL_MAGIC)?;
    if body.len() < 12 {
        return None;
    }
    let nonce: [u8; 12] = body[..12].try_into().ok()?;
    let ciphertext = &body[12..];
    let cipher = ChaCha20Poly1305::new(&Key::from(*key));
    cipher.decrypt(&Nonce::from(nonce), ciphertext).ok()
}

pub fn encode_key(key: &[u8; 32]) -> String {
    base64::engine::general_purpose::STANDARD.encode(key)
}

pub fn decode_key(text: &str) -> Option<[u8; 32]> {
    let bytes = base64::engine::general_purpose::STANDARD.decode(text.trim()).ok()?;
    bytes.try_into().ok()
}

/// Loads the sealing key from `secrets`, or creates and stores a new one if no sealed file exists yet.
/// When a sealed file already exists on disk and the vault does not return the key, returns `None` so those files stay
/// untouched instead of being overwritten with a new key.
pub fn load_or_create_key(secrets: &dyn SecretStore, sealed_paths: &[PathBuf]) -> Option<[u8; 32]> {
    if let Some(stored) = secrets.read(SEAL_KEY_ACCOUNT) {
        return decode_key(&stored);
    }
    let any_sealed = sealed_paths.iter().any(|p| std::fs::read(p).map(|b| is_sealed(&b)).unwrap_or(false));
    if any_sealed {
        log::error!("Autocomplete: the key for the writing samples is not in the credential store; they stay as they are this launch");
        return None;
    }
    let key = <[u8; 32]>::generate();
    if secrets.write(SEAL_KEY_ACCOUNT, &encode_key(&key)).is_ok() {
        Some(key)
    } else {
        None
    }
}

/// Outcome of loading a sealed JSON file.
pub struct SealedLoad<T> {
    pub value: T,
    /// The file on disk is sealed but could not be opened this launch: never overwrite it until the user asks to forget.
    pub locked: bool,
    /// The file on disk was plain JSON and can be re-sealed right away when a key is available.
    pub was_plain: bool,
}

pub fn load_sealed<T: for<'de> Deserialize<'de> + Default>(path: &Path, key: Option<&[u8; 32]>) -> SealedLoad<T> {
    let Ok(bytes) = std::fs::read(path) else {
        return SealedLoad { value: T::default(), locked: false, was_plain: false };
    };
    if is_sealed(&bytes) {
        let Some(key) = key else {
            return SealedLoad { value: T::default(), locked: true, was_plain: false };
        };
        let Some(plain) = open(&bytes, key) else {
            return SealedLoad { value: T::default(), locked: true, was_plain: false };
        };
        match serde_json::from_slice(&plain) {
            Ok(value) => SealedLoad { value, locked: false, was_plain: false },
            Err(_) => SealedLoad { value: T::default(), locked: true, was_plain: false },
        }
    } else {
        match serde_json::from_slice(&bytes) {
            Ok(value) => SealedLoad { value, locked: false, was_plain: true },
            Err(_) => SealedLoad { value: T::default(), locked: false, was_plain: false },
        }
    }
}

pub fn save_sealed<T: Serialize>(value: &T, path: &Path, key: Option<&[u8; 32]>) -> std::io::Result<()> {
    let json = serde_json::to_vec_pretty(value).map_err(std::io::Error::other)?;
    let bytes = match key {
        Some(k) => seal(&json, k).map_err(std::io::Error::other)?,
        None => json,
    };
    paths::write_atomic(path, &bytes)
}

pub fn samples_file() -> PathBuf {
    stats::folder().join("samples.json")
}

pub fn rejected_phrases_file() -> PathBuf {
    stats::folder().join("rejected-phrases.json")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::secrets::MemorySecrets;
    use chrono::Duration;

    fn now() -> DateTime<Utc> {
        DateTime::from_timestamp(1_800_000_000, 0).unwrap()
    }

    fn phrases(texts: &[&str], age_secs: i64) -> CompletionPhrases {
        let ts = now();
        let samples: Vec<Sample> = texts
            .iter()
            .map(|t| Sample { app: "mail".into(), text: (*t).into(), date: ts - Duration::seconds(age_secs), context: None })
            .collect();
        CompletionPhrases::from_samples(&samples, HashMap::new(), ts)
    }

    const GREETINGS: &[&str] = &[
        "Top, ik kijk ernaar. Met vriendelijke groet, Michan",
        "Dank je wel! Met vriendelijke groet, Michan",
        "Prima zo. Met vriendelijke groet, Michan",
        "Ik hoop dat het lukt",
        "Ik hoop dat je komt",
        "Ik hoop dat we winnen",
    ];

    #[test]
    fn samples_grow_in_place_and_vocabulary() {
        let mut samples = CompletionSamples::default();
        let first = "Hoi team, de offerte voor de klant staat klaar in de map";
        samples.add(first, "mail", None, now());
        samples.add(&format!("{first} en de planning ook"), "mail", None, now());
        assert_eq!(samples.len(), 1);
        samples.add("kort", "mail", None, now());
        assert_eq!(samples.len(), 1, "too short to keep");
        samples.add("De offerte gaat morgen naar de klant, de planning volgt later", "slack", None, now());
        assert!(samples.relevant("slack", "", "", 1).first().is_some_and(|s| s.starts_with("De offerte")));
        let words = samples.vocabulary(400);
        assert_eq!(words.get("offerte"), Some(&1.0));
        assert!(!words.contains_key("de"));
    }

    #[test]
    fn short_messages_are_kept_but_not_used_as_style() {
        let mut samples = CompletionSamples::default();
        samples.add("Top, tot morgen!", "chat", None, now());
        assert_eq!(samples.len(), 1);
        assert!(samples.relevant("chat", "", "", 3).is_empty(), "too short to show a style in the prompt");
    }

    #[test]
    fn samples_about_the_same_thing_come_first() {
        let mut samples = CompletionSamples::default();
        samples.add("De offerte voor Jansen staat klaar, de planning volgt morgen", "mail", None, now());
        samples.add("Haha ja, zaterdag naar het strand lijkt me echt top", "chat", None, now());
        samples.add("Zullen we vrijdag gaan eten bij dat nieuwe restaurant?", "chat", None, now());
        let about = samples.relevant("chat", "Gaan we zaterdag naar het strand?", "", 1);
        assert!(about.first().is_some_and(|s| s.starts_with("Haha ja")), "the same subject beats the newest");
        assert!(
            !samples.relevant("chat", "Gaan we zaterdag?", "", 3).iter().any(|s| s.starts_with("De offerte")),
            "another app's writing about something else stays out"
        );
        let mail_match = samples.relevant("chat", "Is de offerte voor Jansen al klaar?", "", 1);
        assert!(mail_match.first().is_some_and(|s| s.starts_with("De offerte")));
        let own = "Zullen we vrijdag gaan eten bij dat nieuwe restaurant? Ik heb er zin in";
        assert!(!samples.relevant("chat", "", own, 3).iter().any(|s| s.starts_with("Zullen we")), "the field's own text is not a sample");
    }

    #[test]
    fn samples_are_found_by_the_context_they_were_written_in() {
        let mut samples = CompletionSamples::default();
        let context = CompletionSamples::context_words("Lisa\nZullen we vrijdag de presentatie voor het kwartaaloverleg doornemen?", 60);
        assert!(context.is_some());
        samples.add("Prima, dan zie ik je om tien uur in de", "chat", context.clone(), now());
        samples.add("Prima, dan zie ik je om tien uur in de kleine zaal!", "chat", None, now());
        assert_eq!(samples.samples.first().and_then(|s| s.context.clone()), context, "a sample that grows keeps its context");
        samples.add("Haha ja, zaterdag naar het strand lijkt me echt top", "chat", None, now());
        let about = samples.relevant("chat", "Kunnen we de presentatie voor het kwartaaloverleg verzetten?", "", 1);
        assert_eq!(about.first().map(String::as_str), Some("Prima, dan zie ik je om tien uur in de kleine zaal!"));
    }

    #[test]
    fn context_words_leave_secrets_out() {
        let words = CompletionSamples::context_words("Wachtwoord: Geheim123!xyz voor de server", 60).unwrap_or_default();
        assert!(!words.contains("geheim123"));
        assert!(CompletionSamples::context_words("", 60).is_none());
    }

    #[test]
    fn only_what_was_typed_is_learned_without_a_suggestion() {
        assert_eq!(CompletionSamples::typed("H", "Hoi Jan, tot morgen").as_deref(), Some("Hoi Jan, tot morgen"));
        let quote = "\n\nOp maandag schreef Piet: kun je de offerte sturen?";
        assert_eq!(
            CompletionSamples::typed(quote, &format!("Ja, ik stuur hem vandaag nog{quote}")).as_deref(),
            Some("Ja, ik stuur hem vandaag nog")
        );
        assert_eq!(
            CompletionSamples::typed("Beste Piet, de offerte", "Beste Piet, de offerte komt morgen").as_deref(),
            Some("offerte komt morgen")
        );
        assert_eq!(CompletionSamples::typed("Hallo", "Hallo"), None);
        assert_eq!(CompletionSamples::typed("Hallo daar", "Hallo"), None);
    }

    #[test]
    fn one_word_alone_does_not_start_a_learned_phrase() {
        let texts = vec!["Hoi Lisa, hoe is het?"; 5];
        let learned = phrases(&texts, 0);
        assert_eq!(learned.predict("Hoi ", 3), None, "who the message is for is not in one word");
        assert_eq!(learned.predict("Hoi L", 1).as_deref(), Some("isa,"));
    }

    #[test]
    fn phrases_written_often_are_suggested() {
        let learned = phrases(GREETINGS, 0);
        assert_eq!(learned.predict("Hoi Lisa, met vriendelijke ", 5).as_deref(), Some(" groet, Michan"));
        assert_eq!(learned.predict("Met vriendelijke gr", 5).as_deref(), Some("oet, Michan"));
        assert_eq!(learned.predict("Met vriendelijke ", 1).as_deref(), Some(" groet,"));
        // Written often, but followed by something else each time: no suggestion.
        assert_eq!(learned.predict("Ik hoop dat ", 5), None);
        assert_eq!(learned.predict("Iets heel anders ", 5), None);
    }

    #[test]
    fn old_writing_counts_less() {
        assert_eq!(phrases(GREETINGS, 180 * 24 * 3600).predict("Met vriendelijke ", 5), None);
    }

    #[test]
    fn turned_down_phrase_counts_less() {
        let mut learned = phrases(GREETINGS, 0);
        let key = CompletionPhrases::rejection_key("Hoi Lisa, met vriendelijke ", "groet, Michan");
        assert_eq!(key.as_deref(), Some("met vriendelijke|groet"));
        learned.reject(key.as_deref().unwrap());
        assert_eq!(learned.predict("Hoi Piet, met vriendelijke ", 5), None);
        assert_eq!(CompletionPhrases::rejection_key("Met vriendelijke gr", "oet, Michan").as_deref(), Some("met vriendelijke|groet"));
    }

    #[test]
    fn frequent_phrases_for_the_prompt() {
        let frequent = phrases(GREETINGS, 0).frequent(12);
        assert_eq!(frequent, vec!["ik hoop dat", "met vriendelijke groet Michan"]);
    }

    #[test]
    fn sealing_round_trip_and_locked_protection() {
        let dir = std::env::temp_dir().join(format!("nook-learn-{}", uuid::Uuid::new_v4()));
        let file = dir.join("samples.json");
        let secrets = MemorySecrets::default();
        let key = load_or_create_key(&secrets, std::slice::from_ref(&file)).expect("creates key");

        let mut samples = CompletionSamples::default();
        samples.add("Top, ik stuur het document zo door naar het team.", "outlook", None, now());
        save_sealed(&samples, &file, Some(&key)).unwrap();

        let raw = std::fs::read(&file).unwrap();
        assert!(is_sealed(&raw));
        assert!(!String::from_utf8_lossy(&raw).contains("document"));

        // Opens with the right key.
        let loaded = load_sealed::<CompletionSamples>(&file, Some(&key));
        assert!(!loaded.locked);
        assert!(!loaded.was_plain);
        assert_eq!(loaded.value, samples);

        // Missing key leaves sealed files locked and does not create a replacement key.
        let empty_secrets = MemorySecrets::default();
        assert!(load_or_create_key(&empty_secrets, std::slice::from_ref(&file)).is_none());
        let locked = load_sealed::<CompletionSamples>(&file, None);
        assert!(locked.locked);
        assert!(locked.value.is_empty());

        // Plain file is read and flagged for re-sealing.
        save_sealed(&samples, &file, None).unwrap();
        let plain = load_sealed::<CompletionSamples>(&file, Some(&key));
        assert!(!plain.locked);
        assert!(plain.was_plain);
        assert_eq!(plain.value, samples);

        let _ = std::fs::remove_dir_all(dir);
    }
}
