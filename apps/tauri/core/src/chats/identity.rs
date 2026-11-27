//! Who a chat is with, the same for every chat app (`ChatIdentity`, `ChatHandle`, `ChatText`, `ChatNames`,
//! `ChatRecipients`, `ChatPeople`, `Fuzzy` on the Mac): a phone number however it is written, an address, a name
//! folded the same way everywhere, disambiguation for two chats with one name in one app, and which chat a name
//! someone typed or said means — never guessing between equal matches.

use std::collections::{HashMap, HashSet};
use std::ops::RangeInclusive;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use unicode_normalization::{char::is_combining_mark, UnicodeNormalization};

use super::{ChatInbox, ChatKind, InboxThread};

/// Unicode decimal digits (`Nd`) mapped to ASCII `0..=9`, so digits in another script (such as Arabic-Indic
/// `٠٦١٢٣٤٥٦٧٨` or fullwidth `０１２３４５６７８９`) produce the same phone key as ASCII digits.
fn unicode_decimal_digit(c: char) -> Option<u8> {
    if c.is_ascii_digit() {
        return Some((c as u32 - '0' as u32) as u8);
    }
    let cp = c as u32;
    // Standard 10-digit Unicode decimal blocks (`Nd`, 0..=9 contiguous).
    const BASES: &[u32] = &[
        0x0660, // Arabic-Indic
        0x06F0, // Extended Arabic-Indic
        0x07C0, // NKo
        0x0966, // Devanagari
        0x09E6, // Bengali
        0x0A66, // Gurmukhi
        0x0AE6, // Gujarati
        0x0B66, // Oriya
        0x0BE6, // Tamil
        0x0C66, // Telugu
        0x0CE6, // Kannada
        0x0D66, // Malayalam
        0x0DE6, // Sinhala Lith
        0x0E50, // Thai
        0x0ED0, // Lao
        0x0F20, // Tibetan
        0x1040, // Myanmar
        0x1090, // Myanmar Shan
        0x17E0, // Khmer
        0x1810, // Mongolian
        0xFF10, // Fullwidth
    ];
    for &base in BASES {
        if (base..=base + 9).contains(&cp) {
            return Some((cp - base) as u8);
        }
    }
    None
}

/// Phone numbers and addresses, one way for every chat app (`ChatHandle` on the Mac): People, calls, tags and
/// "send to" all read a number through here, so `"+31 6 1234 5678"`, `"0612345678"` and `"31612345678@s.whatsapp.net"`
/// are one person everywhere.
pub struct ChatHandle;

impl ChatHandle {
    /// How many digits a phone number has: at least a short local number's six, at most E.164's fifteen. Fewer is a
    /// code or a count, never a person.
    pub const DIGIT_COUNT: RangeInclusive<usize> = 6..=15;
    /// A number is known by its last nine digits, matching a number with or without its country code.
    pub const KEY_LENGTH: usize = 9;

    /// The digits of a number or a WhatsApp id, in ASCII: `"31612345678:3@s.whatsapp.net"` -> `"31612345678"`,
    /// `"+31 6 1234 5678"` -> `"31612345678"`. An id's server (`"@..."`), multi-account prefix (`"account~"`), and
    /// device (`":3"`) are left out.
    pub fn digits(text: &str) -> String {
        let mut user = text;
        if let Some((before_at, _)) = user.split_once('@') {
            let before_at = if Self::is_number_id(text) { before_at.rsplit_once('~').map_or(before_at, |(_, jid)| jid) } else { before_at };
            user = before_at.split_once(':').map_or(before_at, |(num, _)| num);
        }
        user.chars().filter_map(unicode_decimal_digit).map(|d| (b'0' + d) as char).collect()
    }

    /// A WhatsApp id that is a phone number (`"...@s.whatsapp.net"`, `"...@c.us"`): a number, not an address.
    pub fn is_number_id(text: &str) -> bool {
        let Some((_, host)) = text.split_once('@') else { return false };
        let host = host.trim().to_ascii_lowercase();
        host.ends_with("whatsapp.net") || host == "c.us"
    }

    /// A number's key: its last nine digits. `None` for something with too few digits to be a number.
    pub fn phone_key(text: &str) -> Option<String> {
        let digits = Self::digits(text);
        if digits.len() < *Self::DIGIT_COUNT.start() {
            return None;
        }
        let start = digits.len().saturating_sub(Self::KEY_LENGTH);
        Some(digits[start..].to_string())
    }

    /// The same person however the number or address is written: an address in lowercase, a phone number by its last
    /// nine digits. `None` for an empty handle or a number too short to be one.
    pub fn key(handle: &str) -> Option<String> {
        let clean = handle.trim();
        if clean.is_empty() {
            return None;
        }
        if clean.contains('@') && !Self::is_number_id(clean) {
            return Some(clean.to_lowercase());
        }
        Self::phone_key(clean)
    }

    /// `"+31 6 1234 5678"` -> `"+31612345678"` (E.164, as app links take it); `None` for what is no phone number
    /// (a username, an address, too few or too many digits). A number without `"+"` or `"00"` gets a `"+"` before it
    /// as written. Also reads WhatsApp number JIDs (`31612345678@s.whatsapp.net`, `31612345678:3@s.whatsapp.net`,
    /// `31612345678@c.us`, and multi-account keys `nook-abc123~31612345678@s.whatsapp.net`).
    pub fn e164(text: &str) -> Option<String> {
        let mut raw = text.trim();
        if raw.is_empty() {
            return None;
        }
        if let Some((before_at, _)) = raw.split_once('@') {
            if !Self::is_number_id(raw) {
                return None;
            }
            let user = before_at.rsplit_once('~').map_or(before_at, |(_, jid)| jid);
            raw = user.split_once(':').map_or(user, |(num, _)| num);
        }
        if !raw.chars().all(|c| unicode_decimal_digit(c).is_some() || "+-() .".contains(c)) {
            return None;
        }
        let mut digits = Self::digits(raw);
        let leading_zero_zero = {
            let mut it = raw.chars();
            matches!((it.next().and_then(unicode_decimal_digit), it.next().and_then(unicode_decimal_digit)), (Some(0), Some(0)))
        };
        if leading_zero_zero {
            digits.drain(..2);
        }
        Self::DIGIT_COUNT.contains(&digits.len()).then(|| format!("+{digits}"))
    }

    /// Whether `text` is a phone number (`e164` reads it).
    pub fn is_phone(text: &str) -> bool {
        Self::e164(text).is_some()
    }

    /// Whether what someone asked for is meant as a number rather than a name: mostly digits, enough of them.
    pub fn looks_like_number(text: &str) -> bool {
        let digits = Self::digits(text);
        let non_ws = text.chars().filter(|c| !c.is_whitespace()).count();
        digits.len() >= *Self::DIGIT_COUNT.start() && digits.len() * 2 >= non_ws
    }
}

/// Names compared the same way in every chat app (`ChatText` on the Mac): without case, accents or width
/// (`"Ｊｏｓé"` is `"jose"`).
pub struct ChatText;

impl ChatText {
    /// Lowercase, without invisible marks, accents or width differences, trimmed.
    pub fn fold(text: &str) -> String {
        let visible: String = text
            .chars()
            .filter(|c| !matches!(c, '\u{200B}'..='\u{200F}' | '\u{202A}'..='\u{202E}' | '\u{2060}'..='\u{2069}' | '\u{FEFF}'))
            .collect();
        visible.nfkd().filter(|c| !is_combining_mark(*c)).collect::<String>().to_lowercase().trim().to_string()
    }

    /// [`Self::fold`], with every run of what is no letter or digit collapsed to one space:
    /// `"Anna-Marie  (Work)"` -> `"anna marie work"`. What People and "which chat" go by.
    pub fn words(text: &str) -> String {
        Self::fold(text).split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()).collect::<Vec<_>>().join(" ")
    }
}

/// Names as people say or type them (`Fuzzy` on the Mac): `"spotfy"` is Spotify, `"lsia"` is Lisa.
/// Exact, then joined without spaces, then word/prefix, then Levenshtein <= 1 (or <= 2 for >= 7 chars).
/// Never guesses between two equally close distinct candidates.
pub struct Fuzzy;

impl Fuzzy {
    /// Lowercase, without accents, separators or a trailing `".app"`.
    pub fn fold(text: &str) -> String {
        let mut out = ChatText::fold(text);
        if let Some(stripped) = out.strip_suffix(".app") {
            out = stripped.to_string();
        }
        out.split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()).collect::<Vec<_>>().join(" ")
    }

    /// The candidate meant, or `None` when nothing is close enough or two distinct candidates are equally close.
    pub fn best<'a>(query: &str, candidates: &[&'a str]) -> Option<&'a str> {
        let wanted = Self::fold(query);
        if wanted.is_empty() {
            return None;
        }
        let folded: Vec<(&'a str, String)> = candidates.iter().map(|&c| (c, Self::fold(c))).collect();
        let unique = |found: &[(&'a str, &str)]| -> Option<&'a str> {
            let names: HashSet<&'a str> = found.iter().map(|(raw, _)| *raw).collect();
            (names.len() == 1).then(|| *names.iter().next().unwrap())
        };

        let exact: Vec<(&'a str, &str)> = folded.iter().filter(|(_, f)| f == &wanted).map(|(r, f)| (*r, f.as_str())).collect();
        if !exact.is_empty() {
            return unique(&exact);
        }

        let wanted_joined = wanted.replace(' ', "");
        let joined: Vec<(&'a str, &str)> =
            folded.iter().filter(|(_, f)| f.replace(' ', "") == wanted_joined).map(|(r, f)| (*r, f.as_str())).collect();
        if !joined.is_empty() {
            return unique(&joined);
        }

        let wanted_prefix = format!("{wanted} ");
        let prefix: Vec<(&'a str, &str)> = folded
            .iter()
            .filter(|(_, f)| f.starts_with(&wanted_prefix) || f.split(' ').any(|w| w == wanted))
            .map(|(r, f)| (*r, f.as_str()))
            .collect();
        if !prefix.is_empty() {
            return unique(&prefix);
        }

        // Typos: one mistake in a short name, two in a longer one.
        let wanted_len = wanted.chars().count();
        if wanted_len < 4 {
            return None;
        }
        let allowed = if wanted_len >= 7 { 2 } else { 1 };
        let scored: Vec<(&'a str, &str, usize)> = folded
            .iter()
            .filter_map(|(r, f)| {
                let d = Self::distance(&wanted, f);
                (d <= allowed).then_some((*r, f.as_str(), d))
            })
            .collect();
        let least = scored.iter().map(|(_, _, d)| *d).min()?;
        let best_matches: Vec<(&'a str, &str)> = scored.into_iter().filter(|(_, _, d)| *d == least).map(|(r, f, _)| (r, f)).collect();
        unique(&best_matches)
    }

    /// Levenshtein distance (Wagner-Fischer), on characters.
    pub fn distance(a: &str, b: &str) -> usize {
        let x: Vec<char> = a.chars().collect();
        let y: Vec<char> = b.chars().collect();
        if x.is_empty() {
            return y.len();
        }
        if y.is_empty() {
            return x.len();
        }
        let mut previous: Vec<usize> = (0..=y.len()).collect();
        let mut current = vec![0; y.len() + 1];
        for i in 1..=x.len() {
            current[0] = i;
            for j in 1..=y.len() {
                let cost = usize::from(x[i - 1] != y[j - 1]);
                current[j] = (previous[j] + 1).min(current[j - 1] + 1).min(previous[j - 1] + cost);
            }
            std::mem::swap(&mut previous, &mut current);
        }
        previous[y.len()]
    }
}

/// Who a private chat is with, across apps (`ChatIdentity` on the Mac): a phone number ([`ChatHandle::phone_key`]),
/// else an address, else the name.
pub struct ChatIdentity;

impl ChatIdentity {
    /// `"tel:"` and a number's key, else `"mail:"` and the address in lowercase, else `"name:"` and the name's words.
    pub fn key(name: &str, phone: Option<&str>, email: Option<&str>) -> String {
        if let Some(phone) = phone {
            if !phone.contains('@') || ChatHandle::is_number_id(phone) {
                if let Some(key) = ChatHandle::phone_key(phone) {
                    return format!("tel:{key}");
                }
            }
        }
        if let Some(email) = email.map(str::trim) {
            if email.contains('@') && !ChatHandle::is_number_id(email) {
                return format!("mail:{}", email.to_lowercase());
            }
        }
        format!("name:{}", ChatText::words(name))
    }
}

/// One chat passed to [`ChatNames::unique`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NamedChat {
    pub id: String,
    pub app: String,
    pub name: String,
    /// What makes two chats the same one to you (the same person in two threads): they then keep one row.
    pub same: Option<String>,
}

/// Two different chats of one app with one name, told apart in the name they show (`ChatNames` on the Mac):
/// every chat in the shared inbox and every answer goes by that name, so two people called the same never share
/// a row, and an answer never reaches the wrong one. Each gets a short mark made from its own id (FNV-1a), so it
/// stays the same across reads and launches.
pub struct ChatNames;

impl ChatNames {
    const SEPARATOR: &'static str = " \u{00b7} ";

    /// The name each chat shows, by its id: its own, or with its mark when another chat of its app has that name too.
    pub fn unique(chats: &[NamedChat]) -> HashMap<String, String> {
        let mut by_name: HashMap<String, Vec<&NamedChat>> = HashMap::new();
        for chat in chats.iter().filter(|c| !c.name.is_empty()) {
            let key = ChatInbox::key_by_name(&chat.app, &chat.name);
            by_name.entry(key).or_default().push(chat);
        }
        let mut names = HashMap::new();
        for group in by_name.values() {
            let distinct: HashSet<&str> = group.iter().map(|c| c.same.as_deref().unwrap_or(&c.id)).collect();
            let shared = distinct.len() > 1;
            for chat in group {
                let shown = if shared {
                    let seed = chat.same.as_deref().unwrap_or(&chat.id);
                    format!("{}{}{}", chat.name, Self::SEPARATOR, Self::mark(seed))
                } else {
                    chat.name.clone()
                };
                names.insert(chat.id.clone(), shown);
            }
        }
        names
    }

    /// The name a chat had before it got its mark; `None` for a name without one.
    pub fn unmarked(name: &str) -> Option<&str> {
        let (head, tail) = name.rsplit_once(Self::SEPARATOR)?;
        if tail.len() == 4 && tail.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f')) {
            Some(head)
        } else {
            None
        }
    }

    /// Four lowercase hex digits (FNV-1a): stable across runs and platforms.
    fn mark(id: &str) -> String {
        let mut hash: u32 = 2_166_136_261;
        for byte in id.as_bytes() {
            hash = (hash ^ u32::from(*byte)).wrapping_mul(16_777_619);
        }
        format!("{:04x}", hash & 0xffff)
    }
}

/// What a name someone gave finds among chats (`ChatPick` on the Mac): one chat, several that fit equally well
/// (Nook asks which), or none.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChatPick<T> {
    One(T),
    Several(Vec<T>),
    None,
}

impl<T> ChatPick<T> {
    /// The one chat; `None` when there are several or none.
    pub fn found(self) -> Option<T> {
        match self {
            Self::One(item) => Some(item),
            Self::Several(_) | Self::None => None,
        }
    }
}

/// Which chat someone means, the same for every app (`ChatRecipients` on the Mac): by its id, by a number
/// (the last nine digits), else by name: exact, then a whole word of it (a first name), then a part of it
/// (>= 3 characters), then a typo ([`Fuzzy::best`]). Two different chats that fit equally well are never guessed
/// between: the answer is [`ChatPick::Several`], and the caller asks which one.
pub struct ChatRecipients;

impl ChatRecipients {
    pub fn pick<'a, T, FId, FName, FNum, FIsId>(
        wanted: &str,
        items: &'a [T],
        id: FId,
        name: FName,
        number: FNum,
        is_id: FIsId,
    ) -> ChatPick<&'a T>
    where
        FId: Fn(&T) -> &str,
        FName: Fn(&T) -> &str,
        FNum: Fn(&T) -> Option<&str>,
        FIsId: Fn(&str, &T) -> bool,
    {
        let asked = wanted.trim();
        if asked.is_empty() {
            return ChatPick::None;
        }
        let unique = |found: Vec<&'a T>| -> ChatPick<&'a T> {
            let mut seen = HashSet::new();
            let distinct: Vec<&'a T> = found.into_iter().filter(|item| seen.insert(id(item).to_string())).collect();
            match distinct.len() {
                0 => ChatPick::None,
                1 => ChatPick::One(distinct[0]),
                _ => ChatPick::Several(distinct),
            }
        };

        let by_id: Vec<&'a T> = items.iter().filter(|item| is_id(asked, item)).collect();
        if !by_id.is_empty() {
            return unique(by_id);
        }

        if ChatHandle::looks_like_number(asked) {
            let key = ChatHandle::phone_key(asked);
            let by_num: Vec<&'a T> = items.iter().filter(|item| number(item).and_then(ChatHandle::phone_key) == key).collect();
            return unique(by_num);
        }

        let query = ChatText::words(asked);
        if query.is_empty() {
            return ChatPick::None;
        }

        let folded: Vec<(&'a T, String)> = items.iter().map(|item| (item, ChatText::words(name(item)))).collect();

        let exact: Vec<&'a T> = folded.iter().filter(|(_, n)| n == &query).map(|(item, _)| *item).collect();
        if !exact.is_empty() {
            return unique(exact);
        }

        let word: Vec<&'a T> = folded.iter().filter(|(_, n)| n.split(' ').any(|w| w == query)).map(|(item, _)| *item).collect();
        if !word.is_empty() {
            return unique(word);
        }

        if query.chars().count() < 3 {
            return ChatPick::None;
        }

        let partly: Vec<&'a T> = folded.iter().filter(|(_, n)| n.contains(&query)).map(|(item, _)| *item).collect();
        if !partly.is_empty() {
            return unique(partly);
        }

        // A typo ("Lsia"): the one name that is close, never a guess between two.
        let names: Vec<&str> = items.iter().map(&name).collect();
        let Some(close) = Fuzzy::best(asked, &names) else { return ChatPick::None };
        let by_typo: Vec<&'a T> = items.iter().filter(|item| name(item) == close).collect();
        unique(by_typo)
    }
}

/// One chat belonging to a [`ChatPerson`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatPersonChat {
    /// The chat's key in [`ChatInbox`].
    pub chat: String,
    pub app: String,
    pub last: DateTime<Utc>,
    pub unread: usize,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub avatar: Option<String>,
}

/// One person across every chat app (`ChatPerson` on the Mac), with the private chats they are in.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatPerson {
    /// The same person's key in every launch ([`InboxThread::identity`]): a phone number when a chat has one,
    /// else an address, else the folded name.
    pub id: String,
    pub name: String,
    /// Their chats, newest first.
    pub chats: Vec<ChatPersonChat>,
}

impl ChatPerson {
    pub fn last_interaction(&self) -> DateTime<Utc> {
        self.chats.first().map_or(DateTime::<Utc>::MIN_UTC, |c| c.last)
    }

    pub fn unread(&self) -> usize {
        self.chats.iter().map(|c| c.unread).sum()
    }

    pub fn avatar(&self) -> Option<&str> {
        self.chats.iter().find_map(|c| c.avatar.as_deref())
    }

    /// The apps they are in, each once, the one written in last first.
    pub fn apps(&self) -> Vec<&str> {
        let mut seen = HashSet::new();
        self.chats.iter().map(|c| c.app.as_str()).filter(|a| seen.insert(*a)).collect()
    }
}

/// Deduplicates private chats into people across apps (`ChatPeople` on the Mac).
pub struct ChatPeople;

impl ChatPeople {
    /// Finds each person once across apps. A private chat is the same person as another when they share a phone
    /// number, else an address, else the same name in the same letters ([`InboxThread::identity`]); a group,
    /// status update, channel, or automated bot is no person.
    pub fn people<'a>(threads: impl IntoIterator<Item = &'a InboxThread>) -> Vec<ChatPerson> {
        let mut by_key: HashMap<String, ChatPerson> = HashMap::new();
        for thread in threads {
            if thread.notice_kind() != ChatKind::Person || thread.is_automated() {
                continue;
            }
            let last = thread.last();
            if last <= DateTime::<Utc>::MIN_UTC || thread.name.trim().is_empty() {
                continue;
            }
            let key = thread.identity();
            let chat = ChatPersonChat {
                chat: thread.id.clone(),
                app: thread.app.clone(),
                last,
                unread: thread.unread,
                avatar: thread.avatar.clone(),
            };
            by_key.entry(key.clone()).and_modify(|p| p.chats.push(chat.clone())).or_insert_with(|| ChatPerson {
                id: key,
                name: thread.name.clone(),
                chats: vec![chat],
            });
        }
        let mut list: Vec<ChatPerson> = by_key
            .into_values()
            .map(|mut person| {
                person.chats.sort_by(|a, b| b.last.cmp(&a.last).then_with(|| a.chat.cmp(&b.chat)));
                person
            })
            .collect();
        list.sort_by(|a, b| b.last_interaction().cmp(&a.last_interaction()).then_with(|| a.name.cmp(&b.name)));
        list
    }

    /// A person's key from a handle alone (a number or an address), else their folded name ([`ChatIdentity::key`]).
    pub fn key(name: &str, handle: Option<&str>) -> String {
        ChatIdentity::key(name, handle, handle)
    }

    pub fn fold(text: &str) -> String {
        ChatText::words(text)
    }

    /// People matching a search by name, the same fold on both sides.
    pub fn search<'a>(people: &'a [ChatPerson], query: &str) -> Vec<&'a ChatPerson> {
        let needle = Self::fold(query);
        if needle.is_empty() {
            return people.iter().collect();
        }
        people.iter().filter(|p| Self::fold(&p.name).contains(&needle)).collect()
    }
}

#[cfg(test)]
mod tests {
    use chrono::TimeZone;

    use super::*;
    use crate::chats::{BridgedChat, ChatProfile, InboxMessage};

    fn now() -> DateTime<Utc> {
        Utc.timestamp_opt(1_800_000_000, 0).unwrap()
    }

    fn thread(app: &str, name: &str, handle: Option<&str>, phone: Option<&str>, email: Option<&str>) -> InboxThread {
        let mut t = InboxThread::new(format!("{app}|{name}"), app, name);
        t.messages = vec![InboxMessage::new("m", "hello", now(), false)];
        t.kind = Some(ChatKind::Person);
        t.handle = handle.map(str::to_string);
        if phone.is_some() || email.is_some() {
            t.profile = Some(ChatProfile { phone: phone.map(str::to_string), email: email.map(str::to_string), ..Default::default() });
        }
        t
    }

    fn inbox(threads: Vec<InboxThread>) -> ChatInbox {
        let mut inbox = ChatInbox::default();
        for t in threads {
            inbox.threads.insert(t.id.clone(), t);
        }
        inbox
    }

    // --- Numbers (mirrors ChatIdentityTests.swift) ---

    #[test]
    fn one_number_key_for_every_way_of_writing_it() {
        let key = ChatHandle::key("+31 6 1234 5678");
        assert_eq!(key.as_deref(), Some("612345678"));
        assert_eq!(ChatHandle::key("0612345678"), key);
        assert_eq!(ChatHandle::key("31612345678@s.whatsapp.net"), key);
        assert_eq!(ChatHandle::key("31612345678:3@s.whatsapp.net"), key, "a device suffix is no part of the number");
        assert_eq!(ChatHandle::key("nook-acc1~31612345678:3@s.whatsapp.net"), key, "multi-account prefix is stripped");
        assert_eq!(ChatHandle::key("Lisa@Example.com").as_deref(), Some("lisa@example.com"));
        assert_eq!(ChatHandle::key("٠٦١٢٣٤٥٦٧٨"), key, "digits in another script are the same digits");
        assert_eq!(ChatHandle::key(""), None);
    }

    #[test]
    fn one_minimum_length_for_a_number() {
        assert_eq!(*ChatHandle::DIGIT_COUNT.start(), 6);
        assert_eq!(ChatHandle::phone_key("123456").as_deref(), Some("123456"));
        assert_eq!(ChatHandle::phone_key("12345"), None);
        assert_eq!(ChatHandle::e164("123456").as_deref(), Some("+123456"));
        assert_eq!(ChatHandle::e164("12345"), None);
        assert_eq!(ChatHandle::e164("1234567890123456"), None, "E.164 has fifteen digits at most");
        assert_eq!(ChatHandle::e164("0031 6 12345678").as_deref(), Some("+31612345678"));
        assert_eq!(crate::chats::call::phone_digits("0031 6 12345678").as_deref(), Some("+31612345678"));
        assert!(ChatHandle::looks_like_number("06 1234 5678"));
        assert!(!ChatHandle::looks_like_number("Anna 2"));
    }

    #[test]
    fn one_fold_for_names() {
        assert_eq!(ChatText::fold("  Zoë "), "zoe");
        assert_eq!(ChatText::fold("Ｊｏｓé"), "jose", "width and accents both go");
        assert_eq!(ChatText::words("Anna-Marie  (Work)"), "anna marie work");
        assert_eq!(ChatPeople::fold("Anna-Marie"), ChatText::words("Anna-Marie"));
    }

    // --- Identity ---

    #[test]
    fn identity_comes_from_what_each_app_says() {
        assert_eq!(thread("whatsapp", "Anna", Some("31612345678@s.whatsapp.net"), None, None).identity(), "tel:612345678");
        assert_eq!(thread("telegram", "Anna", None, Some("+31 6 1234 5678"), None).identity(), "tel:612345678");
        assert_eq!(thread("slack", "Anna", None, None, Some("Anna@Contoso.com")).identity(), "mail:anna@contoso.com");
        assert_eq!(thread("messages", "Anna", Some("anna@icloud.com"), None, None).identity(), "mail:anna@icloud.com");
        assert_eq!(thread("signal", "Anna-Marie", None, None, None).identity(), "name:anna marie");
        assert_eq!(thread("teams", "Anna", None, None, Some("anna@contoso.com")).contact_handle(), Some("anna@contoso.com"));
    }

    #[test]
    fn people_join_the_same_person_by_number_and_address_across_apps() {
        let threads = vec![
            thread("whatsapp", "Anna de Vries", Some("+31 6 1234 5678"), None, None),
            thread("telegram", "Anna", None, Some("0612345678"), None),
            thread("slack", "Anna V.", None, None, Some("anna@contoso.com")),
            thread("teams", "Anna de Vries (Contoso)", None, None, Some("ANNA@contoso.com")),
            thread("signal", "Bob", None, None, None),
        ];
        let people = ChatPeople::people(&threads);
        assert_eq!(people.len(), 3);
        let mut tel_apps = people.iter().find(|p| p.id == "tel:612345678").unwrap().apps();
        tel_apps.sort_unstable();
        assert_eq!(tel_apps, vec!["telegram", "whatsapp"]);
        let mut mail_apps = people.iter().find(|p| p.id == "mail:anna@contoso.com").unwrap().apps();
        mail_apps.sort_unstable();
        assert_eq!(mail_apps, vec!["slack", "teams"]);
    }

    fn bridged(app: &str, name: &str, messages: Vec<InboxMessage>) -> BridgedChat {
        BridgedChat { app: app.into(), name: name.into(), messages, ..Default::default() }
    }

    #[test]
    fn a_bridge_without_a_handle_gets_the_one_its_profile_says() {
        let mut inbox = ChatInbox::default();
        let mut chat = bridged("telegram", "Anna", vec![InboxMessage::new("1", "hi", now(), false)]);
        chat.unread = Some(1);
        chat.kind = Some(ChatKind::Person);
        chat.profile = Some(ChatProfile { phone: Some("+31612345678".into()), ..Default::default() });
        assert!(inbox.merge(chat, now()));
        assert_eq!(inbox.threads.values().next().and_then(|t| t.handle.as_deref()), Some("+31612345678"));

        let mut group = bridged("telegram", "Team", vec![InboxMessage::new("2", "hi", now(), false)]);
        group.unread = Some(1);
        group.kind = Some(ChatKind::Group);
        group.profile = Some(ChatProfile { phone: Some("+31600000000".into()), ..Default::default() });
        inbox.merge(group, now());
        assert_eq!(inbox.threads.get(&ChatInbox::key_by_name("telegram", "Team")).and_then(|t| t.handle.as_deref()), None);
    }

    // --- Which chat ---

    #[test]
    fn a_name_that_fits_two_chats_is_never_a_guess() {
        let inbox = inbox(vec![
            thread("whatsapp", "Anna de Vries", None, None, None),
            thread("telegram", "Anna Bakker", None, None, None),
            thread("signal", "Bob", None, None, None),
        ]);
        let both = match inbox.pick("Anna", None, |_| true) {
            ChatPick::Several(list) => list,
            other => panic!("expected several Annas, got {other:?}"),
        };
        let apps: HashSet<&str> = both.iter().map(|t| t.app.as_str()).collect();
        assert_eq!(apps, HashSet::from(["whatsapp", "telegram"]));
        assert!(inbox.thread_named("Anna", None, |_| true).is_none());
        assert_eq!(inbox.thread_named("Anna", Some("telegram"), |_| true).map(|t| t.name.as_str()), Some("Anna Bakker"));
        assert_eq!(inbox.thread_named("anna de vries", None, |_| true).map(|t| t.app.as_str()), Some("whatsapp"));
        assert_eq!(inbox.thread_named("Bakker", None, |_| true).map(|t| t.app.as_str()), Some("telegram"));
        assert_eq!(inbox.thread_named("Ana de Vries", None, |_| true).map(|t| t.app.as_str()), Some("whatsapp"));
        assert!(ChatInbox::which("Anna", &both).contains("WhatsApp"));
        assert!(matches!(inbox.pick("Zed", None, |_| true), ChatPick::None));
    }

    #[test]
    fn a_chat_is_found_by_its_number_or_id_in_every_app() {
        let anna = thread("telegram", "Anna", None, Some("+31 6 1234 5678"), None);
        let anna_id = anna.id.clone();
        let inbox = inbox(vec![anna, thread("signal", "Bob", None, Some("+31 6 0000 0000"), None)]);
        assert_eq!(inbox.thread_named("0612345678", None, |_| true).map(|t| t.name.as_str()), Some("Anna"));
        assert!(inbox.thread_named("0699999999", None, |_| true).is_none(), "a number nobody has finds no one, not a name");
        assert_eq!(inbox.thread_named(&anna_id, None, |_| true).map(|t| t.name.as_str()), Some("Anna"));
    }

    #[test]
    fn two_chats_with_one_name_in_one_app_are_told_apart_by_their_id() {
        let messages = vec![InboxMessage::new("m", "hello", now(), false)];
        let mut work = InboxThread::new("whatsapp#31611111111@s.whatsapp.net", "whatsapp", "Arjan");
        work.messages = messages.clone();
        let mut home = InboxThread::new("whatsapp#31622222222@s.whatsapp.net", "whatsapp", "Arjan");
        home.messages = messages;
        let work_id = work.id.clone();
        let home_id = home.id.clone();
        let inbox = inbox(vec![work, home]);
        let both = match inbox.pick("Arjan", Some("whatsapp"), |_| true) {
            ChatPick::Several(list) => list,
            other => panic!("expected two Arjans, got {other:?}"),
        };
        let answer = ChatInbox::which("Arjan", &both);
        assert!(answer.contains(&format!("id: {work_id}")) && answer.contains(&format!("id: {home_id}")), "{answer}");
        assert_eq!(inbox.thread_named(&home_id, Some("whatsapp"), |_| true).map(|t| t.id.as_str()), Some(home_id.as_str()));
    }

    // --- ChatNames ---

    #[test]
    fn chat_names_disambiguate_two_chats_with_same_name_and_keep_same_person_together() {
        let names = ChatNames::unique(&[
            NamedChat { id: "c1".into(), app: "telegram".into(), name: "Alex".into(), same: None },
            NamedChat { id: "c2".into(), app: "telegram".into(), name: "Alex".into(), same: None },
            NamedChat { id: "c3".into(), app: "signal".into(), name: "Alex".into(), same: None },
            NamedChat { id: "ig1".into(), app: "instagram".into(), name: "Bo".into(), same: Some("acc|@bo".into()) },
            NamedChat { id: "ig2".into(), app: "instagram".into(), name: "Bo".into(), same: Some("acc|@bo".into()) },
        ]);
        assert_ne!(names["c1"], "Alex");
        assert_ne!(names["c2"], "Alex");
        assert_ne!(names["c1"], names["c2"]);
        assert_eq!(ChatNames::unmarked(&names["c1"]), Some("Alex"));
        assert_eq!(ChatNames::unmarked(&names["c2"]), Some("Alex"));
        assert_eq!(names["c3"], "Alex", "different app keeps plain name");
        assert_eq!(names["ig1"], "Bo", "same person across threads stays unmarked");
        assert_eq!(names["ig2"], "Bo");
        assert_eq!(ChatNames::unmarked("Alex"), None);
        assert_eq!(ChatNames::unmarked("Alex · ZZZZ"), None);
    }

    #[test]
    fn unmarked_chat_cleanup_removes_old_shared_row_on_merge() {
        let mut inbox = ChatInbox::default();
        let old = bridged("telegram", "Alex", vec![InboxMessage::new("1", "hi", now(), false)]);
        inbox.merge(old, now());
        assert!(inbox.threads.contains_key(&ChatInbox::key_by_name("telegram", "Alex")));

        let names = ChatNames::unique(&[
            NamedChat { id: "1".into(), app: "telegram".into(), name: "Alex".into(), same: None },
            NamedChat { id: "2".into(), app: "telegram".into(), name: "Alex".into(), same: None },
        ]);
        let marked = bridged("telegram", &names["1"], vec![InboxMessage::new("2", "yo", now(), false)]);
        inbox.merge(marked, now());
        assert!(!inbox.threads.contains_key(&ChatInbox::key_by_name("telegram", "Alex")));
        assert!(inbox.threads.contains_key(&ChatInbox::key_by_name("telegram", &names["1"])));
    }

    #[test]
    fn fuzzy_matches_typos_and_refuses_ties() {
        assert_eq!(Fuzzy::best("Lissa", &["Lisa", "Bob"]), Some("Lisa"));
        assert_eq!(Fuzzy::best("Spotfy", &["Spotify", "Safari"]), Some("Spotify"));
        assert_eq!(Fuzzy::best("Liza", &["Lisa", "Lina"]), None, "two equally close names never guess");
        assert_eq!(Fuzzy::best("Li", &["Lisa"]), None, "short query does not typo-match");
    }

    #[test]
    fn bots_and_groups_are_excluded_from_people() {
        let mut bot = thread("telegram", "WeatherBot", None, None, None);
        bot.profile = Some(ChatProfile { bot: true, ..Default::default() });
        let mut grp = thread("slack", "Team", None, None, None);
        grp.kind = Some(ChatKind::Group);
        let real = thread("signal", "Bo", None, None, None);
        let people = ChatPeople::people(&[bot, grp, real]);
        assert_eq!(people.len(), 1);
        assert_eq!(people[0].name, "Bo");
    }
}
