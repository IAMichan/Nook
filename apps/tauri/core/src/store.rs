use std::path::Path;
use std::sync::Mutex;

use chrono::{DateTime, TimeZone, Utc};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{de::DeserializeOwned, Deserialize, Serialize};

use crate::{paths, Result};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenLoop {
    pub id: String,
    pub title: String,
    pub source: String,
    pub created: DateTime<Utc>,
    pub due: Option<DateTime<Utc>>,
}

/// Eén regel van het actielogboek: wat Nook (namens de gebruiker) deed.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AuditEntry {
    pub id: i64,
    pub date: DateTime<Utc>,
    pub tool: String,
    pub args: String,
    pub result: String,
}

/// Nooks eigen gegevens: open punten, het actielogboek en het geheugen. Alles blijft lokaal.
/// Zelfde schema en migraties als `NookStore` op de Mac (`PRAGMA user_version`), zodat een database overdraagbaar is.
pub struct NookStore {
    db: Mutex<Connection>,
}

/// Hoe lang het actielogboek bewaard wordt; het kan berichttekst bevatten.
pub const AUDIT_RETENTION_SECS: i64 = 90 * 86_400;

const MIGRATIONS: [&str; 3] = [
    "CREATE TABLE IF NOT EXISTS loops (
        id TEXT PRIMARY KEY, title TEXT NOT NULL, source TEXT NOT NULL, created REAL NOT NULL, due REAL,
        done INTEGER NOT NULL DEFAULT 0);
     CREATE TABLE IF NOT EXISTS executed_actions (key TEXT PRIMARY KEY, ts REAL NOT NULL, tool TEXT NOT NULL, result TEXT NOT NULL);
     CREATE TABLE IF NOT EXISTS audit (id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, tool TEXT NOT NULL,
        args TEXT NOT NULL, result TEXT NOT NULL);",
    "CREATE INDEX IF NOT EXISTS audit_ts ON audit (ts);",
    "CREATE TABLE IF NOT EXISTS memories (id TEXT PRIMARY KEY, body TEXT NOT NULL, updated REAL NOT NULL);
     CREATE TABLE IF NOT EXISTS memory_state (key TEXT PRIMARY KEY, body TEXT NOT NULL);",
];

fn ts(date: DateTime<Utc>) -> f64 {
    date.timestamp_millis() as f64 / 1000.0
}

fn date(ts: f64) -> DateTime<Utc> {
    Utc.timestamp_millis_opt((ts * 1000.0) as i64).single().unwrap_or_default()
}

fn now() -> f64 {
    ts(Utc::now())
}

fn prefix(text: &str, max: usize) -> String {
    text.chars().take(max).collect()
}

impl NookStore {
    pub fn open_default() -> Result<Self> {
        Self::open(&paths::database_file())
    }

    pub fn open(path: &Path) -> Result<Self> {
        let conn = Connection::open(path)?;
        paths::restrict(path, 0o600);
        conn.pragma_update(None, "journal_mode", "WAL")?;
        let store = Self { db: Mutex::new(conn) };
        store.migrate()?;
        store.prune_audit();
        Ok(store)
    }

    pub fn in_memory() -> Result<Self> {
        let store = Self { db: Mutex::new(Connection::open_in_memory()?) };
        store.migrate()?;
        Ok(store)
    }

    fn conn(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.db.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn schema_version(&self) -> i64 {
        self.conn().query_row("PRAGMA user_version", [], |r| r.get(0)).unwrap_or(0)
    }

    fn migrate(&self) -> Result<()> {
        let current = self.schema_version() as usize;
        let mut conn = self.conn();
        for (index, sql) in MIGRATIONS.iter().enumerate().skip(current) {
            let tx = conn.transaction()?;
            tx.execute_batch(sql)?;
            tx.pragma_update(None, "user_version", (index + 1) as i64)?;
            tx.commit()?;
        }
        Ok(())
    }

    // Open punten

    pub fn add_loop(&self, title: &str, source: &str, due: Option<DateTime<Utc>>) -> OpenLoop {
        let lp = OpenLoop {
            id: uuid::Uuid::new_v4().to_string().to_uppercase(),
            title: title.into(),
            source: source.into(),
            created: Utc::now(),
            due,
        };
        let _ = self.conn().execute(
            "INSERT INTO loops (id, title, source, created, due, done) VALUES (?1, ?2, ?3, ?4, ?5, 0)",
            params![lp.id, lp.title, lp.source, ts(lp.created), lp.due.map(ts)],
        );
        lp
    }

    pub fn open_loops(&self) -> Vec<OpenLoop> {
        let conn = self.conn();
        let Ok(mut stmt) = conn.prepare("SELECT id, title, source, created, due FROM loops WHERE done = 0 ORDER BY created ASC") else {
            return vec![];
        };
        stmt.query_map([], |r| {
            Ok(OpenLoop {
                id: r.get(0)?,
                title: r.get(1)?,
                source: r.get(2)?,
                created: date(r.get(3)?),
                due: r.get::<_, Option<f64>>(4)?.map(date),
            })
        })
        .map(|rows| rows.flatten().collect())
        .unwrap_or_default()
    }

    pub fn complete_loop(&self, id: &str) {
        let _ = self.conn().execute("UPDATE loops SET done = 1 WHERE id = ?1", params![id]);
    }

    /// Op id, op een uniek begin van het id (minstens 6 tekens) of op de precieze titel.
    pub fn complete_loop_matching(&self, id_or_title: &str) -> Option<OpenLoop> {
        let loops = self.open_loops();
        let needle = id_or_title.trim();
        let lower = needle.to_lowercase();
        let by_prefix: Vec<&OpenLoop> =
            if needle.chars().count() >= 6 { loops.iter().filter(|l| l.id.to_lowercase().starts_with(&lower)).collect() } else { vec![] };
        let found = loops
            .iter()
            .find(|l| l.id == needle)
            .or(if by_prefix.len() == 1 { Some(by_prefix[0]) } else { None })
            .or_else(|| loops.iter().find(|l| l.title.to_lowercase() == lower))?
            .clone();
        self.complete_loop(&found.id);
        Some(found)
    }

    // Uitgevoerde acties (nooit twee keer hetzelfde na een herhaalpoging)

    pub fn executed_action(&self, key: &str, within_secs: i64) -> Option<DateTime<Utc>> {
        self.conn()
            .query_row("SELECT ts FROM executed_actions WHERE key = ?1 AND ts >= ?2", params![key, now() - within_secs as f64], |r| {
                r.get::<_, f64>(0)
            })
            .optional()
            .ok()
            .flatten()
            .map(date)
    }

    pub fn record_executed(&self, key: &str, tool: &str, result: &str) {
        let conn = self.conn();
        let _ = conn.execute(
            "INSERT OR REPLACE INTO executed_actions (key, ts, tool, result) VALUES (?1, ?2, ?3, ?4)",
            params![key, now(), tool, prefix(result, 500)],
        );
        let _ = conn.execute("DELETE FROM executed_actions WHERE ts < ?1", params![now() - 7.0 * 86_400.0]);
    }

    // Actielogboek

    pub fn audit(&self, tool: &str, args: &str, result: &str) {
        let _ = self.conn().execute(
            "INSERT INTO audit (ts, tool, args, result) VALUES (?1, ?2, ?3, ?4)",
            params![now(), tool, prefix(args, 2000), prefix(result, 2000)],
        );
    }

    /// Nieuwste eerst; `matching` filtert op toolnaam of tekst.
    pub fn audit_entries(&self, limit: usize, matching: &str) -> Vec<AuditEntry> {
        let conn = self.conn();
        let filter = matching.trim();
        let map = |r: &rusqlite::Row<'_>| {
            Ok(AuditEntry { id: r.get(0)?, date: date(r.get(1)?), tool: r.get(2)?, args: r.get(3)?, result: r.get(4)? })
        };
        let result = if filter.is_empty() {
            conn.prepare("SELECT id, ts, tool, args, result FROM audit ORDER BY ts DESC, id DESC LIMIT ?1")
                .and_then(|mut s| s.query_map(params![limit as i64], map).map(|rows| rows.flatten().collect()))
        } else {
            conn.prepare(
                "SELECT id, ts, tool, args, result FROM audit WHERE tool LIKE ?2 OR args LIKE ?2 OR result LIKE ?2 ORDER BY ts DESC, id DESC LIMIT ?1",
            )
            .and_then(|mut s| s.query_map(params![limit as i64, format!("%{filter}%")], map).map(|rows| rows.flatten().collect()))
        };
        result.unwrap_or_default()
    }

    pub fn prune_audit(&self) {
        let _ = self.conn().execute("DELETE FROM audit WHERE ts < ?1", params![now() - AUDIT_RETENTION_SECS as f64]);
    }

    pub fn clear_audit(&self) {
        let _ = self.conn().execute("DELETE FROM audit", []);
    }

    // Geheugen: rijen als JSON, zodat een nieuwere versie velden kan toevoegen.

    /// Alles wat bewaard is. Een rij die niet te lezen is (van een nieuwere versie) wordt overgeslagen, nooit gewist.
    pub fn memories<T: DeserializeOwned>(&self) -> Vec<T> {
        let conn = self.conn();
        let Ok(mut stmt) = conn.prepare("SELECT body FROM memories ORDER BY updated ASC") else { return vec![] };
        stmt.query_map([], |r| r.get::<_, String>(0))
            .map(|rows| rows.flatten().filter_map(|b| serde_json::from_str(&b).ok()).collect())
            .unwrap_or_default()
    }

    pub fn save_memory<T: Serialize>(&self, id: &str, updated: DateTime<Utc>, item: &T) {
        if let Ok(body) = serde_json::to_string(item) {
            let _ = self
                .conn()
                .execute("INSERT OR REPLACE INTO memories (id, body, updated) VALUES (?1, ?2, ?3)", params![id, body, ts(updated)]);
        }
    }

    pub fn delete_memory(&self, id: &str) {
        let _ = self.conn().execute("DELETE FROM memories WHERE id = ?1", params![id]);
    }

    pub fn clear_memories(&self) {
        let _ = self.conn().execute_batch("DELETE FROM memories; DELETE FROM memory_state;");
    }

    pub fn memory_state(&self, key: &str) -> Option<String> {
        self.conn().query_row("SELECT body FROM memory_state WHERE key = ?1", params![key], |r| r.get(0)).optional().ok().flatten()
    }

    pub fn set_memory_state(&self, key: &str, body: &str) {
        let _ = self.conn().execute("INSERT OR REPLACE INTO memory_state (key, body) VALUES (?1, ?2)", params![key, body]);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn migrates_to_latest() {
        let s = NookStore::in_memory().unwrap();
        assert_eq!(s.schema_version(), MIGRATIONS.len() as i64);
    }

    #[test]
    fn loops_complete_by_prefix_and_title() {
        let s = NookStore::in_memory().unwrap();
        let a = s.add_loop("Lisa terugbellen", "chat", None);
        s.add_loop("Factuur sturen", "chat", None);
        assert_eq!(s.open_loops().len(), 2);
        assert_eq!(s.complete_loop_matching(&a.id[..8]).map(|l| l.id), Some(a.id));
        assert_eq!(s.complete_loop_matching("factuur sturen").map(|l| l.title), Some("Factuur sturen".into()));
        assert!(s.open_loops().is_empty());
    }

    #[test]
    fn audit_filters_and_orders() {
        let s = NookStore::in_memory().unwrap();
        s.audit("create_event", "{}", "ok");
        s.audit("send_mail", "{\"to\":\"lisa\"}", "ok");
        let all = s.audit_entries(10, "");
        assert_eq!(all[0].tool, "send_mail");
        assert_eq!(s.audit_entries(10, "lisa").len(), 1);
    }

    #[test]
    fn executed_actions_expire() {
        let s = NookStore::in_memory().unwrap();
        s.record_executed("k", "tool", "ok");
        assert!(s.executed_action("k", 60).is_some());
        assert!(s.executed_action("other", 60).is_none());
    }

    #[test]
    fn memories_round_trip() {
        #[derive(Serialize, Deserialize, PartialEq, Debug)]
        struct M {
            text: String,
        }
        let s = NookStore::in_memory().unwrap();
        s.save_memory("1", Utc::now(), &M { text: "Lisa is mijn vrouw".into() });
        assert_eq!(s.memories::<M>(), vec![M { text: "Lisa is mijn vrouw".into() }]);
        s.set_memory_state("x", "{}");
        assert_eq!(s.memory_state("x").as_deref(), Some("{}"));
        s.clear_memories();
        assert!(s.memories::<M>().is_empty());
    }
}
