//! Het gesprek van een sessie uit het transcript van de agent zelf (`AgentTranscript` op de Mac): opdrachten,
//! antwoorden en denkstappen; tool-aanroepen en systeemtekst vallen weg. Kent Claude Code, Codex en Antigravity
//! (JSONL) en Gemini CLI (één JSON-bestand per chat).

use std::collections::HashMap;
use std::io::{Read, Seek, SeekFrom};
use std::sync::Mutex;
use std::time::SystemTime;

use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ChatKind {
    User,
    Assistant,
    Thinking,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentChatMessage {
    pub id: String,
    pub kind: ChatKind,
    pub text: String,
}

/// Zoveel bytes van het eind van een JSONL-bestand: genoeg voor bijna elk gesprek.
const TAIL_BYTES: u64 = 8_000_000;
const MAX_MESSAGE: usize = 24_000;
pub const FULL_LIMIT: usize = 1_000;

struct CacheEntry {
    size: u64,
    modified: SystemTime,
    limit: usize,
    messages: Vec<AgentChatMessage>,
}

static CACHE: Mutex<Option<HashMap<String, CacheEntry>>> = Mutex::new(None);

pub fn recent(path: &str, limit: usize) -> Vec<AgentChatMessage> {
    let is_gemini = path.ends_with(".json");
    if !path.ends_with(".jsonl") && !is_gemini {
        return vec![];
    }
    let meta = std::fs::metadata(path).ok();
    let (size, modified) = (meta.as_ref().map(|m| m.len()), meta.as_ref().and_then(|m| m.modified().ok()));
    if let (Some(size), Some(modified)) = (size, modified) {
        let cache = CACHE.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(hit) = cache.as_ref().and_then(|c| c.get(path)) {
            if hit.size == size && hit.modified == modified && hit.limit >= limit {
                return tail(&hit.messages, limit);
            }
        }
    }
    let messages = if is_gemini {
        match std::fs::read(path) {
            Ok(data) => gemini(&data),
            Err(_) => return vec![],
        }
    } else {
        let Ok(mut file) = std::fs::File::open(path) else { return vec![] };
        let end = file.seek(SeekFrom::End(0)).unwrap_or(0);
        let start = end.saturating_sub(TAIL_BYTES);
        let _ = file.seek(SeekFrom::Start(start));
        let mut data = Vec::new();
        if file.read_to_end(&mut data).is_err() {
            return vec![];
        }
        // Midden in een regel begonnen: die halve regel overslaan.
        if start > 0 {
            if let Some(nl) = data.iter().position(|b| *b == b'\n') {
                data.drain(..=nl);
            }
        }
        jsonl(&data)
    };
    let result = tail(&messages, limit);
    if let (Some(size), Some(modified)) = (size, modified) {
        let mut cache = CACHE.lock().unwrap_or_else(|e| e.into_inner());
        let map = cache.get_or_insert_with(HashMap::new);
        if map.len() > 64 {
            map.clear();
        }
        map.insert(path.into(), CacheEntry { size, modified, limit, messages: result.clone() });
    }
    result
}

fn tail(messages: &[AgentChatMessage], limit: usize) -> Vec<AgentChatMessage> {
    messages[messages.len().saturating_sub(limit)..].to_vec()
}

fn s<'a>(v: &'a Value, key: &str) -> &'a str {
    v.get(key).and_then(Value::as_str).unwrap_or("")
}

/// Claude Code, Antigravity en Codex: één JSON-object per regel.
pub fn jsonl(data: &[u8]) -> Vec<AgentChatMessage> {
    let mut messages = vec![];
    for (index, line) in data.split(|b| *b == b'\n').enumerate() {
        let Ok(object) = serde_json::from_slice::<Value>(line) else { continue };
        let id = object
            .get("uuid")
            .and_then(Value::as_str)
            .or_else(|| object.get("id").and_then(Value::as_str))
            .map(str::to_string)
            .unwrap_or_else(|| object.get("step_index").map(|v| v.to_string()).unwrap_or_else(|| index.to_string()));
        let kind = s(&object, "type");
        match kind {
            "user" | "assistant" => {
                if object.get("isMeta").and_then(Value::as_bool) == Some(true)
                    || object.get("isSidechain").and_then(Value::as_bool) == Some(true)
                {
                    continue;
                }
                let Some(message) = object.get("message") else { continue };
                if kind == "user" {
                    let t = blocks_text(message.get("content")).trim().to_string();
                    if t.is_empty() || !is_typed_prompt(&t) {
                        continue;
                    }
                    messages.push(AgentChatMessage { id, kind: ChatKind::User, text: clip(&t) });
                } else {
                    append_thinking(&thinking_text(message.get("content")), &id, &mut messages);
                    append_reply(&blocks_text(message.get("content")), &id, &mut messages);
                }
            }
            "USER_INPUT" => {
                let Some(raw) = object.get("content").and_then(Value::as_str) else { continue };
                let t = clean_antigravity_prompt(raw);
                if !t.is_empty() {
                    messages.push(AgentChatMessage { id, kind: ChatKind::User, text: clip(&t) });
                }
            }
            "PLANNER_RESPONSE" => {
                append_thinking(s(&object, "thinking"), &id, &mut messages);
                append_reply(s(&object, "content"), &id, &mut messages);
            }
            "event_msg" => {
                let Some(payload) = object.get("payload") else { continue };
                match s(payload, "type") {
                    "user_message" => {
                        let t = s(payload, "message").trim();
                        if !t.is_empty() {
                            messages.push(AgentChatMessage { id, kind: ChatKind::User, text: clip(t) });
                        }
                    }
                    "agent_message" => append_reply(s(payload, "message"), &id, &mut messages),
                    "agent_reasoning" => append_thinking(s(payload, "text"), &id, &mut messages),
                    _ => {}
                }
            }
            _ => {}
        }
    }
    messages
}

/// Gemini CLI: `{"messages": [{"type": "user" | "gemini", "content": …, "thoughts": [{"subject", "description"}]}]}`.
pub fn gemini(data: &[u8]) -> Vec<AgentChatMessage> {
    let Ok(root) = serde_json::from_slice::<Value>(data) else { return vec![] };
    let Some(list) = root.get("messages").and_then(Value::as_array) else { return vec![] };
    let mut messages = vec![];
    for (index, message) in list.iter().enumerate() {
        let id = message.get("id").and_then(Value::as_str).map(str::to_string).unwrap_or_else(|| format!("gemini-{index}"));
        let content = gemini_text(message.get("content"));
        match s(message, "type") {
            "user" if !content.is_empty() => messages.push(AgentChatMessage { id, kind: ChatKind::User, text: clip(&content) }),
            "gemini" => {
                let thoughts: Vec<String> = message
                    .get("thoughts")
                    .and_then(Value::as_array)
                    .map(|list| {
                        list.iter()
                            .filter_map(|t| {
                                let subject = s(t, "subject").trim();
                                let description = s(t, "description").trim();
                                match (subject.is_empty(), description.is_empty()) {
                                    (true, true) => None,
                                    (true, false) => Some(description.to_string()),
                                    (false, true) => Some(format!("**{subject}**")),
                                    (false, false) => Some(format!("**{subject}**\n{description}")),
                                }
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                append_thinking(&thoughts.join("\n\n"), &id, &mut messages);
                append_reply(&content, &id, &mut messages);
            }
            _ => {}
        }
    }
    messages
}

/// Denken direct na denken wordt één ballon.
fn append_thinking(raw: &str, id: &str, messages: &mut Vec<AgentChatMessage>) {
    let thinking = raw.trim();
    if thinking.is_empty() {
        return;
    }
    if let Some(last) = messages.last_mut().filter(|m| m.kind == ChatKind::Thinking) {
        last.text = clip(&format!("{}\n\n{thinking}", last.text));
    } else {
        messages.push(AgentChatMessage { id: format!("{id}-think"), kind: ChatKind::Thinking, text: clip(thinking) });
    }
}

/// Antwoord direct na antwoord wordt één ballon.
fn append_reply(raw: &str, id: &str, messages: &mut Vec<AgentChatMessage>) {
    let text = raw.trim();
    if text.is_empty() {
        return;
    }
    if let Some(last) = messages.last_mut().filter(|m| m.kind == ChatKind::Assistant) {
        last.text = clip(&format!("{}\n\n{text}", last.text));
    } else {
        messages.push(AgentChatMessage { id: id.into(), kind: ChatKind::Assistant, text: clip(text) });
    }
}

pub fn gemini_text(content: Option<&Value>) -> String {
    match content {
        Some(Value::String(s)) => s.trim().to_string(),
        Some(Value::Array(parts)) => {
            parts.iter().filter_map(|p| p.get("text").and_then(Value::as_str)).collect::<Vec<_>>().join("\n").trim().to_string()
        }
        _ => String::new(),
    }
}

/// De opdracht uit een Antigravity-prompt, zonder de omhullende tags en metadata.
pub fn clean_antigravity_prompt(raw: &str) -> String {
    let lower = raw.to_ascii_lowercase();
    if let Some(start) = lower.find("<user_request>") {
        let from = start + "<user_request>".len();
        if let Some(end) = lower[from..].find("</user_request>") {
            return raw[from..from + end].trim().to_string();
        }
    }
    let mut text = raw.to_string();
    for tag in ["ADDITIONAL_METADATA", "USER_SETTINGS_CHANGE", "uploaded_files"] {
        loop {
            let lower = text.to_ascii_lowercase();
            let open = format!("<{}>", tag.to_lowercase());
            let close = format!("</{}>", tag.to_lowercase());
            let Some(start) = lower.find(&open) else { break };
            let Some(end) = lower[start..].find(&close) else { break };
            text.replace_range(start..start + end + close.len(), "");
        }
    }
    text.trim().to_string()
}

/// Tekst van een bericht: een string, of de tekstblokken uit een lijst.
pub fn blocks_text(content: Option<&Value>) -> String {
    match content {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Array(blocks)) => blocks
            .iter()
            .filter(|b| b.get("type").and_then(Value::as_str) == Some("text"))
            .filter_map(|b| b.get("text").and_then(Value::as_str))
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    }
}

fn thinking_text(content: Option<&Value>) -> String {
    content
        .and_then(Value::as_array)
        .map(|blocks| {
            blocks
                .iter()
                .filter(|b| b.get("type").and_then(Value::as_str) == Some("thinking"))
                .filter_map(|b| b.get("thinking").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default()
}

/// Echte opdrachten, niet wat Claude Code zelf invoegt (commando's, uitvoer, onderbrekingen).
pub fn is_typed_prompt(text: &str) -> bool {
    let t = text.trim();
    !t.is_empty()
        && !["<command-", "<local-command", "<system-reminder", "<bash-", "<user-memory", "Caveat:", "[Request interrupted"]
            .iter()
            .any(|p| t.starts_with(p))
}

fn clip(text: &str) -> String {
    if text.chars().count() > MAX_MESSAGE {
        text.chars().take(MAX_MESSAGE - 1).collect::<String>() + "…"
    } else {
        text.into()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn claude_transcript() {
        let data = br#"{"type":"user","uuid":"u1","message":{"content":"Schrijf tests"}}
{"type":"user","uuid":"u2","message":{"content":"<command-name>/clear</command-name>"}}
{"type":"assistant","uuid":"a1","message":{"content":[{"type":"thinking","thinking":"Even denken"},{"type":"text","text":"Klaar."}]}}
{"type":"assistant","uuid":"a2","message":{"content":[{"type":"text","text":"Nog iets."}]}}
{"type":"user","uuid":"u3","isSidechain":true,"message":{"content":"nee"}}"#;
        let m = jsonl(data);
        let kinds: Vec<ChatKind> = m.iter().map(|x| x.kind).collect();
        assert_eq!(kinds, vec![ChatKind::User, ChatKind::Thinking, ChatKind::Assistant]);
        assert_eq!(m[2].text, "Klaar.\n\nNog iets.");
        assert_eq!(m[1].id, "a1-think");
    }

    #[test]
    fn codex_and_antigravity() {
        let data = br#"{"type":"event_msg","payload":{"type":"user_message","message":"Fix"}}
{"type":"event_msg","payload":{"type":"agent_reasoning","text":"Kijken"}}
{"type":"event_msg","payload":{"type":"agent_message","message":"Gedaan"}}
{"type":"USER_INPUT","step_index":4,"content":"<ADDITIONAL_METADATA>x</ADDITIONAL_METADATA><USER_REQUEST> Hoi </USER_REQUEST>"}"#;
        let m = jsonl(data);
        assert_eq!(m.len(), 4);
        assert_eq!(m[3].text, "Hoi");
        assert_eq!(clean_antigravity_prompt("a <uploaded_files>z</uploaded_files> b"), "a  b");
    }

    #[test]
    fn gemini_chat() {
        let data = br#"{"messages":[{"type":"user","content":"Vraag"},{"type":"gemini","content":[{"text":"Antwoord"}],"thoughts":[{"subject":"Plan","description":"stap"}]}]}"#;
        let m = gemini(data);
        assert_eq!(m[1].text, "**Plan**\nstap");
        assert_eq!(m[2].text, "Antwoord");
    }
}
