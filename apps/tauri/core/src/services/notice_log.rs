//! The notices Nook gave (an agent is done, a request waits, a message came in), kept so one you missed (a card that
//! closed by itself, a strip while you were away, a notice held back during a meeting) can still be read and opened
//! (the Mac's `NoticeLog`). In memory only: a notice can quote a message or a command, and neither belongs on disk.

use serde::Serialize;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum NoticeKind {
    Done,
    Failed,
    Waiting,
    Info,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NoticeEntry {
    pub id: u64,
    /// Notices about the same thing (one chat, one session) share a key: a newer one replaces the older.
    pub key: String,
    pub kind: NoticeKind,
    pub title: String,
    pub detail: String,
    /// Who and where ("Claude Code · nook", "WhatsApp").
    pub context: String,
    /// Milliseconds since 1970.
    pub date: i64,
    /// Where a click takes you: a main-window route ("agent:<id>", "chat:<key>", "nook:<id>", "agents", "chats").
    pub route: String,
    pub seen: bool,
}

pub const LIMIT: usize = 100;
pub const MAX_AGE_MS: i64 = 7 * 24 * 3600 * 1000;
pub const DETAIL_LIMIT: usize = 400;

#[derive(Debug, Default)]
pub struct NoticeLog {
    entries: Vec<NoticeEntry>,
    next: u64,
}

impl NoticeLog {
    /// Newest first.
    pub fn entries(&self) -> &[NoticeEntry] {
        &self.entries
    }

    pub fn unseen(&self) -> usize {
        self.entries.iter().filter(|e| !e.seen).count()
    }

    /// Adds a notice on top; one with the same key goes, and the oldest fall off past `LIMIT` or `MAX_AGE_MS`.
    #[allow(clippy::too_many_arguments)]
    pub fn add(&mut self, key: &str, kind: NoticeKind, title: &str, detail: &str, context: &str, route: &str, now: i64) {
        let title = title.trim();
        if title.is_empty() {
            return;
        }
        let detail = detail.trim();
        let detail = if detail.chars().count() > DETAIL_LIMIT {
            format!("{}…", detail.chars().take(DETAIL_LIMIT).collect::<String>())
        } else {
            detail.to_string()
        };
        self.next += 1;
        self.entries.retain(|e| e.key != key);
        self.entries.insert(
            0,
            NoticeEntry {
                id: self.next,
                key: key.into(),
                kind,
                title: title.into(),
                detail,
                context: context.trim().into(),
                date: now,
                route: route.into(),
                seen: false,
            },
        );
        self.prune(now);
    }

    pub fn prune(&mut self, now: i64) {
        self.entries.retain(|e| now - e.date <= MAX_AGE_MS);
        self.entries.truncate(LIMIT);
    }

    pub fn mark_all_seen(&mut self) {
        self.entries.iter_mut().for_each(|e| e.seen = true);
    }

    pub fn mark_seen(&mut self, id: u64) {
        if let Some(e) = self.entries.iter_mut().find(|e| e.id == id) {
            e.seen = true;
        }
    }

    pub fn remove(&mut self, id: u64) {
        self.entries.retain(|e| e.id != id);
    }

    pub fn clear(&mut self) {
        self.entries.clear();
    }

    /// The entries whose title, detail or context hold every word of `query` (case and accents aside).
    pub fn search(&self, query: &str) -> Vec<NoticeEntry> {
        let fold = |t: &str| crate::services::nudge_filter::normalize(t);
        let words: Vec<String> = fold(query).split(' ').filter(|w| !w.is_empty()).map(String::from).collect();
        self.entries
            .iter()
            .filter(|e| {
                let hay = fold(&format!("{} {} {}", e.title, e.detail, e.context));
                words.iter().all(|w| hay.contains(w.as_str()))
            })
            .cloned()
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_the_newest_per_key_and_finds_by_words() {
        let mut log = NoticeLog::default();
        log.add("chat:anna", NoticeKind::Info, "Anna", "See you at 3?", "Telegram", "chat:anna", 1_000);
        log.add("agent:1", NoticeKind::Done, "Fix the login", "Done", "Claude Code · nook", "agent:1", 2_000);
        log.add("chat:anna", NoticeKind::Info, "Anna", "Running late", "Telegram", "chat:anna", 3_000);
        assert_eq!(log.entries().len(), 2);
        assert_eq!(log.entries()[0].detail, "Running late");
        assert_eq!(log.unseen(), 2);
        assert_eq!(log.search("claude LOGIN").len(), 1);
        assert_eq!(log.search("").len(), 2);
        let id = log.entries()[0].id;
        log.mark_seen(id);
        assert_eq!(log.unseen(), 1);
        log.remove(id);
        assert_eq!(log.entries().len(), 1);
    }

    #[test]
    fn forgets_what_is_old_or_too_much() {
        let mut log = NoticeLog::default();
        for i in 0..120 {
            log.add(&format!("k{i}"), NoticeKind::Info, "t", "", "", "", 1_000 + i);
        }
        assert_eq!(log.entries().len(), LIMIT);
        log.prune(1_000 + MAX_AGE_MS + 200);
        assert!(log.entries().is_empty());
        log.add("x", NoticeKind::Info, "   ", "", "", "", 0);
        assert!(log.entries().is_empty());
    }
}
