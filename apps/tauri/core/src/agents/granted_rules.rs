//! Granted permission rules per project (`GrantedRules` in `PermissionScope.swift` on the Mac) and the approval audit
//! log (`ApprovalAudit.swift` on the Mac).
//!
//! Two complementary sources hold granted rules for a project:
//! - Claude Code's own settings files (`<project>/.claude/settings.local.json`, `<project>/.claude/settings.json`, and
//!   `~/.claude/settings.json`), read and revoked directly via their `permissions.allow` array while leaving all other
//!   keys untouched.
//! - Nook's own persisted store (`agent-granted-rules.json`), populated whenever the user clicks "Always" on a hook
//!   approval so grants across all agents are visible per project and revocable.
//!
//! Every decision on a hook approval (allow, always, deny, terminal, or expired) is also appended to a bounded,
//! searchable approval audit log (`agent-approval-audit.json`) with the same formatting as macOS `ApprovalAudit`.

use std::collections::{BTreeMap, HashSet};
use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::permission_scope::{self, Reach};
use super::text::project_name;

/// The audit tool name matching macOS `ApprovalAudit.tool`.
pub const APPROVAL_AUDIT_TOOL: &str = "agent_approval";

/// Maximum length of the requested command/summary kept in an audit entry (`ApprovalAudit.limit` on macOS).
pub const AUDIT_ASKED_LIMIT: usize = 400;

/// Maximum number of entries retained in the approval audit log.
pub const MAX_AUDIT_ENTRIES: usize = 500;

/// Stable wire identifier for [`Reach`].
pub fn reach_id(reach: Reach) -> &'static str {
    match reach {
        Reach::Project => "project",
        Reach::SharedProject => "sharedProject",
        Reach::User => "user",
        Reach::Session => "session",
        Reach::AgentDecides => "agentDecides",
    }
}

pub fn parse_reach(raw: &str) -> Reach {
    match raw {
        "project" => Reach::Project,
        "sharedProject" => Reach::SharedProject,
        "user" => Reach::User,
        "session" => Reach::Session,
        _ => Reach::AgentDecides,
    }
}

fn reach_rank(reach: &str) -> u8 {
    match reach {
        "project" => 0,
        "sharedProject" => 1,
        "session" => 2,
        "agentDecides" => 3,
        "user" => 4,
        _ => 5,
    }
}

/// Normalize a project directory path for map lookup (strip trailing slashes, keep root as-is).
pub fn normalize_project_path(path: &str) -> String {
    let trimmed = path.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    let stripped = trimmed.trim_end_matches(['/', '\\']);
    if stripped.is_empty() {
        trimmed.to_string()
    } else {
        stripped.to_string()
    }
}

/// One granted rule returned to the interface (`GrantedRules.Entry` on macOS, enriched with project & metadata).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GrantedRuleEntry {
    pub id: String,
    pub project: String,
    pub project_name: String,
    pub rule: String,
    pub reach: String,
    pub reach_label: String,
    /// Settings file holding the rule (`.claude/settings*.json`), or empty when tracked only in Nook's store.
    pub file: String,
    pub agent: String,
    pub granted_at: Option<DateTime<Utc>>,
}

/// A rule persisted in Nook's own store (`agent-granted-rules.json`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StoredRule {
    pub rule: String,
    pub reach: String,
    pub agent: String,
    pub granted_at: DateTime<Utc>,
}

// MARK: Claude settings JSON helpers (1-to-1 with macOS `GrantedRules`)

/// Reads `permissions.allow` entries from a Claude settings JSON buffer.
pub fn entries_from_json(json: &[u8], project: &str, reach: Reach, file: &str) -> Vec<GrantedRuleEntry> {
    let Ok(root) = serde_json::from_slice::<Value>(json) else { return vec![] };
    let Some(allow) = root.get("permissions").and_then(|p| p.get("allow")).and_then(Value::as_array) else {
        return vec![];
    };
    let normalized = normalize_project_path(project);
    let p_name = if normalized.is_empty() { String::new() } else { project_name(&normalized) };
    let r_id = reach_id(reach).to_string();
    let r_label = permission_scope::word(reach).to_string();
    allow
        .iter()
        .filter_map(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(|rule| GrantedRuleEntry {
            id: format!("{file}|{rule}"),
            project: normalized.clone(),
            project_name: p_name.clone(),
            rule: rule.to_string(),
            reach: r_id.clone(),
            reach_label: r_label.clone(),
            file: file.to_string(),
            agent: "Claude Code".to_string(),
            granted_at: None,
        })
        .collect()
}

/// Returns the settings JSON with `rule` removed from `permissions.allow`, keeping all other keys untouched.
/// Returns `None` if `rule` is not present or JSON is not a valid settings object.
pub fn removing_rule_from_json(rule: &str, json: &[u8]) -> Option<Vec<u8>> {
    let mut root = serde_json::from_slice::<Value>(json).ok()?;
    let allow = root.get_mut("permissions")?.get_mut("allow")?.as_array_mut()?;
    let before = allow.len();
    allow.retain(|item| item.as_str() != Some(rule));
    if allow.len() == before {
        return None;
    }
    serde_json::to_vec_pretty(&root).ok()
}

/// Removes all rules from `permissions.allow` in a settings JSON buffer, returning `(updated_json, removed_count)`.
pub fn clearing_rules_from_json(json: &[u8]) -> Option<(Vec<u8>, usize)> {
    let mut root = serde_json::from_slice::<Value>(json).ok()?;
    let allow = root.get_mut("permissions")?.get_mut("allow")?.as_array_mut()?;
    let removed = allow.len();
    if removed == 0 {
        return None;
    }
    allow.clear();
    let bytes = serde_json::to_vec_pretty(&root).ok()?;
    Some((bytes, removed))
}

/// Reads Claude Code's granted rules for `directory` (`.claude/settings.local.json`, `.claude/settings.json`) and
/// optionally `home` (`<home>/.claude/settings.json`).
pub fn read_claude_rules(directory: &str, home: Option<&Path>) -> Vec<GrantedRuleEntry> {
    let mut out = Vec::new();
    let dir = normalize_project_path(directory);
    if !dir.is_empty() {
        let base = PathBuf::from(&dir);
        for (path, reach) in [
            (base.join(".claude").join("settings.local.json"), Reach::Project),
            (base.join(".claude").join("settings.json"), Reach::SharedProject),
        ] {
            if let Ok(bytes) = std::fs::read(&path) {
                out.extend(entries_from_json(&bytes, &dir, reach, &path.to_string_lossy()));
            }
        }
    }
    if let Some(home_dir) = home {
        let user_path = home_dir.join(".claude").join("settings.json");
        if let Ok(bytes) = std::fs::read(&user_path) {
            out.extend(entries_from_json(&bytes, "", Reach::User, &user_path.to_string_lossy()));
        }
    }
    out
}

/// Revokes a single rule from a Claude settings JSON file on disk atomically.
pub fn revoke_rule_in_file(path: &Path, rule: &str) -> Result<bool, String> {
    let bytes = match std::fs::read(path) {
        Ok(b) => b,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(e) => return Err(format!("Could not read {}: {e}", path.display())),
    };
    let Some(updated) = removing_rule_from_json(rule, &bytes) else {
        return Ok(false);
    };
    crate::paths::write_atomic(path, &updated).map_err(|e| format!("Could not write {}: {e}", path.display()))?;
    Ok(true)
}

/// Clears all project-scoped Claude `permissions.allow` rules for `directory` (local + shared settings files).
pub fn clear_project_claude_files(directory: &str) -> Result<usize, String> {
    let dir = normalize_project_path(directory);
    if dir.is_empty() {
        return Ok(0);
    }
    let base = PathBuf::from(&dir);
    let mut total = 0usize;
    for path in [base.join(".claude").join("settings.local.json"), base.join(".claude").join("settings.json")] {
        let bytes = match std::fs::read(&path) {
            Ok(b) => b,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
            Err(e) => return Err(format!("Could not read {}: {e}", path.display())),
        };
        if let Some((updated, count)) = clearing_rules_from_json(&bytes) {
            crate::paths::write_atomic(&path, &updated).map_err(|e| format!("Could not write {}: {e}", path.display()))?;
            total += count;
        }
    }
    Ok(total)
}

// MARK: Persisted per-project store

/// Persisted store of granted permission rules keyed by normalized project path (`agent-granted-rules.json`).
#[derive(Debug, Default)]
pub struct GrantedRulesStore {
    file: Option<PathBuf>,
    by_project: BTreeMap<String, Vec<StoredRule>>,
}

impl GrantedRulesStore {
    pub fn load(file: Option<PathBuf>) -> Self {
        let by_project = file
            .as_ref()
            .and_then(|p| std::fs::read(p).ok())
            .and_then(|b| serde_json::from_slice::<BTreeMap<String, Vec<StoredRule>>>(&b).ok())
            .unwrap_or_default();
        Self { file, by_project }
    }

    fn save(&self) {
        let Some(file) = &self.file else { return };
        if let Ok(bytes) = serde_json::to_vec_pretty(&self.by_project) {
            let _ = crate::paths::write_atomic(file, &bytes);
        }
    }

    /// Records a rule granted for `project` when the user chooses "Always".
    pub fn add(&mut self, project: &str, rule: &str, reach: Reach, agent: &str, now: DateTime<Utc>) {
        let rule = rule.trim();
        if rule.is_empty() {
            return;
        }
        let key = if reach == Reach::User { String::new() } else { normalize_project_path(project) };
        let r_id = reach_id(reach).to_string();
        let list = self.by_project.entry(key).or_default();
        if let Some(existing) = list.iter_mut().find(|r| r.rule == rule && r.reach == r_id) {
            existing.agent = agent.to_string();
            existing.granted_at = now;
        } else {
            list.push(StoredRule {
                rule: rule.to_string(),
                reach: r_id,
                agent: agent.to_string(),
                granted_at: now,
            });
        }
        self.save();
    }

    /// Removes one rule from Nook's store (and from `file` on disk if supplied).
    pub fn revoke(&mut self, project: &str, rule: &str, file: Option<&str>) -> Result<bool, String> {
        let mut removed = false;
        if let Some(path) = file.filter(|f| !f.trim().is_empty()) {
            removed |= revoke_rule_in_file(Path::new(path), rule)?;
        }
        let key = normalize_project_path(project);
        for candidate in [key.as_str(), ""] {
            if let Some(list) = self.by_project.get_mut(candidate) {
                let before = list.len();
                list.retain(|r| r.rule != rule);
                if list.len() != before {
                    removed = true;
                }
                if list.is_empty() {
                    self.by_project.remove(candidate);
                }
            }
        }
        if removed {
            self.save();
        }
        Ok(removed)
    }

    /// Revokes all project-scoped rules for `project` (both Claude settings files and Nook's store).
    pub fn revoke_project(&mut self, project: &str) -> Result<usize, String> {
        let key = normalize_project_path(project);
        let mut removed = clear_project_claude_files(&key)?;
        if let Some(stored) = self.by_project.remove(&key) {
            // Avoid double-counting rules that lived in both Claude's settings file and our store.
            removed = removed.max(stored.len());
            self.save();
        }
        Ok(removed)
    }

    /// All project paths known to Nook's granted-rules store.
    pub fn projects(&self) -> Vec<String> {
        self.by_project.keys().filter(|k| !k.is_empty()).cloned().collect()
    }

    /// Lists granted rules for a single project (if `project` is `Some`), or across `extra_projects` + stored projects.
    /// Merges Claude settings files with Nook's stored rules and deduplicates by `(project, reach, rule)`.
    pub fn list(&self, project: Option<&str>, extra_projects: &[String], home: Option<&Path>) -> Vec<GrantedRuleEntry> {
        let mut projects: Vec<String> = Vec::new();
        let mut seen_projects: HashSet<String> = HashSet::new();
        let mut push_project = |p: &str| {
            let norm = normalize_project_path(p);
            if !norm.is_empty() && seen_projects.insert(norm.clone()) {
                projects.push(norm);
            }
        };

        if let Some(single) = project.filter(|p| !p.trim().is_empty()) {
            push_project(single);
        } else {
            for p in self.by_project.keys() {
                push_project(p);
            }
            for p in extra_projects {
                push_project(p);
            }
        }

        let mut out: Vec<GrantedRuleEntry> = Vec::new();
        let mut seen_keys: HashSet<(String, String, String)> = HashSet::new();

        // 1. Claude settings files first (they carry the concrete file path needed to edit `.claude/settings*.json`).
        for dir in &projects {
            for entry in read_claude_rules(dir, None) {
                let dedup = (entry.project.clone(), entry.reach.clone(), entry.rule.clone());
                if seen_keys.insert(dedup) {
                    out.push(entry);
                }
            }
        }
        if let Some(home_dir) = home {
            for entry in read_claude_rules("", Some(home_dir)) {
                let dedup = (entry.project.clone(), entry.reach.clone(), entry.rule.clone());
                if seen_keys.insert(dedup) {
                    out.push(entry);
                }
            }
        }

        // 2. Stored rules from Nook's store (fills in non-Claude agents and freshly granted rules, and attaches
        //    `granted_at` / `agent` metadata to matching Claude entries).
        let stored_keys: Vec<String> = if project.is_some_and(|p| !p.trim().is_empty()) {
            let mut ks = projects.clone();
            ks.push(String::new());
            ks
        } else {
            self.by_project.keys().cloned().collect()
        };

        for key in stored_keys {
            let Some(list) = self.by_project.get(&key) else { continue };
            let p_name = if key.is_empty() { String::new() } else { project_name(&key) };
            for item in list {
                let dedup = (key.clone(), item.reach.clone(), item.rule.clone());
                if let Some(existing) = out.iter_mut().find(|e| e.project == key && e.reach == item.reach && e.rule == item.rule) {
                    existing.granted_at = Some(item.granted_at);
                    if !item.agent.is_empty() {
                        existing.agent = item.agent.clone();
                    }
                    continue;
                }
                if seen_keys.insert(dedup) {
                    let reach = parse_reach(&item.reach);
                    out.push(GrantedRuleEntry {
                        id: format!("store:{key}|{}|{}", item.reach, item.rule),
                        project: key.clone(),
                        project_name: p_name.clone(),
                        rule: item.rule.clone(),
                        reach: item.reach.clone(),
                        reach_label: permission_scope::word(reach).to_string(),
                        file: String::new(),
                        agent: item.agent.clone(),
                        granted_at: Some(item.granted_at),
                    });
                }
            }
        }

        out.sort_by(|a, b| {
            a.project
                .is_empty()
                .cmp(&b.project.is_empty())
                .then_with(|| a.project_name.to_lowercase().cmp(&b.project_name.to_lowercase()))
                .then_with(|| reach_rank(&a.reach).cmp(&reach_rank(&b.reach)))
                .then_with(|| a.rule.cmp(&b.rule))
        });
        out
    }
}

// MARK: Approval Audit Log (`ApprovalAudit` on macOS — AG-42)

/// Where a decision on an approval was made (`ApprovalSource` on macOS).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ApprovalSource {
    App,
    Notification,
    Phone,
}

impl ApprovalSource {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::App => "app",
            Self::Notification => "notification",
            Self::Phone => "phone",
        }
    }
}

/// One structured entry in the approval audit log.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ApprovalAuditEntry {
    pub id: String,
    pub timestamp: DateTime<Utc>,
    pub agent: String,
    pub project: String,
    pub project_path: String,
    pub tool: String,
    pub summary: String,
    pub decision: String,
    #[serde(default)]
    pub scope: Option<String>,
    #[serde(default)]
    pub source: Option<ApprovalSource>,
    #[serde(default)]
    pub danger: bool,
    /// Formatted args matching macOS `ApprovalAudit.entry`: `"Agent · project · tool · summary"`.
    pub args: String,
    /// Formatted result matching macOS `ApprovalAudit.entry`: `"allow · app"` / `"deny · notification · danger"`.
    pub result: String,
}

fn truncate_asked(asked: &str) -> String {
    if asked.chars().count() > AUDIT_ASKED_LIMIT {
        format!("{}…", asked.chars().take(AUDIT_ASKED_LIMIT).collect::<String>())
    } else {
        asked.to_string()
    }
}

fn join_non_empty(parts: &[&str]) -> String {
    parts.iter().copied().filter(|s| !s.is_empty()).collect::<Vec<_>>().join(" · ")
}

impl ApprovalAuditEntry {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        agent: &str,
        project: &str,
        project_path: &str,
        tool: &str,
        asked: &str,
        decision: &str,
        scope: Option<String>,
        source: Option<ApprovalSource>,
        danger: bool,
        timestamp: DateTime<Utc>,
    ) -> Self {
        let shown = truncate_asked(asked);
        let args = join_non_empty(&[agent, project, tool, &shown]);
        let src = source.map(ApprovalSource::as_str).unwrap_or("");
        let danger_word = if danger { "danger" } else { "" };
        let result = join_non_empty(&[decision, src, danger_word]);
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            timestamp,
            agent: agent.to_string(),
            project: project.to_string(),
            project_path: normalize_project_path(project_path),
            tool: tool.to_string(),
            summary: shown,
            decision: decision.to_string(),
            scope,
            source,
            danger,
            args,
            result,
        }
    }

    /// A request nobody answered in time: logged as `"expired"` (`ApprovalAudit.expired` on macOS).
    pub fn expired(agent: &str, project: &str, project_path: &str, tool: &str, asked: &str, timestamp: DateTime<Utc>) -> Self {
        Self::new(agent, project, project_path, tool, asked, "expired", None, None, false, timestamp)
    }
}

/// Bounded, persisted approval audit log (`agent-approval-audit.json`).
#[derive(Debug, Default)]
pub struct ApprovalAuditLog {
    file: Option<PathBuf>,
    entries: Vec<ApprovalAuditEntry>,
}

impl ApprovalAuditLog {
    pub fn load(file: Option<PathBuf>) -> Self {
        let mut entries = file
            .as_ref()
            .and_then(|p| std::fs::read(p).ok())
            .and_then(|b| serde_json::from_slice::<Vec<ApprovalAuditEntry>>(&b).ok())
            .unwrap_or_default();
        if entries.len() > MAX_AUDIT_ENTRIES {
            entries.truncate(MAX_AUDIT_ENTRIES);
        }
        Self { file, entries }
    }

    fn save(&self) {
        let Some(file) = &self.file else { return };
        if let Ok(bytes) = serde_json::to_vec_pretty(&self.entries) {
            let _ = crate::paths::write_atomic(file, &bytes);
        }
    }

    /// Prepends an entry (newest first) and trims to [`MAX_AUDIT_ENTRIES`].
    pub fn record(&mut self, entry: ApprovalAuditEntry) {
        self.entries.insert(0, entry);
        if self.entries.len() > MAX_AUDIT_ENTRIES {
            self.entries.truncate(MAX_AUDIT_ENTRIES);
        }
        self.save();
    }

    /// Returns up to `limit` entries (newest first), optionally filtered by a case-insensitive substring query.
    pub fn list(&self, limit: usize, query: Option<&str>) -> Vec<ApprovalAuditEntry> {
        let q = query.map(|s| s.trim().to_lowercase()).filter(|s| !s.is_empty());
        self.entries
            .iter()
            .filter(|e| match &q {
                None => true,
                Some(needle) => {
                    e.agent.to_lowercase().contains(needle)
                        || e.project.to_lowercase().contains(needle)
                        || e.tool.to_lowercase().contains(needle)
                        || e.summary.to_lowercase().contains(needle)
                        || e.decision.to_lowercase().contains(needle)
                        || e.scope.as_deref().is_some_and(|s| s.to_lowercase().contains(needle))
                        || e.args.to_lowercase().contains(needle)
                        || e.result.to_lowercase().contains(needle)
                }
            })
            .take(limit)
            .cloned()
            .collect()
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn clear(&mut self) {
        self.entries.clear();
        self.save();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("nook-{tag}-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn claude_settings_read_and_revoke_preserves_other_keys() {
        let raw = br#"{"model":"opus","permissions":{"allow":["Bash(git status:*)","Edit"],"deny":["Bash(rm:*)"]}}"#;
        let entries = entries_from_json(raw, "/w/app", Reach::Project, "/w/app/.claude/settings.local.json");
        assert_eq!(entries.iter().map(|e| e.rule.as_str()).collect::<Vec<_>>(), vec!["Bash(git status:*)", "Edit"]);
        assert_eq!(entries[0].reach, "project");
        assert_eq!(entries[0].project_name, "app");

        let revoked = removing_rule_from_json("Edit", raw).expect("Edit should be removed");
        let root: Value = serde_json::from_slice(&revoked).unwrap();
        assert_eq!(root["model"], "opus");
        assert_eq!(root["permissions"]["allow"], json!(["Bash(git status:*)"]));
        assert_eq!(root["permissions"]["deny"], json!(["Bash(rm:*)"]));
        assert!(removing_rule_from_json("Nope", raw).is_none());
    }

    #[test]
    fn granted_rules_store_merges_claude_files_and_revokes_individually_and_per_project() {
        let root = temp_dir("granted-rules");
        let project = root.join("my-app");
        let home = root.join("home");
        std::fs::create_dir_all(project.join(".claude")).unwrap();
        std::fs::create_dir_all(home.join(".claude")).unwrap();
        let local_file = project.join(".claude").join("settings.local.json");
        let shared_file = project.join(".claude").join("settings.json");
        let user_file = home.join(".claude").join("settings.json");

        std::fs::write(&local_file, r#"{"permissions":{"allow":["Bash(git status:*)","Edit"]}}"#).unwrap();
        std::fs::write(&shared_file, r#"{"permissions":{"allow":["Read"]}}"#).unwrap();
        std::fs::write(&user_file, r#"{"permissions":{"allow":["WebSearch"]}}"#).unwrap();

        let store_path = root.join("agent-granted-rules.json");
        let mut store = GrantedRulesStore::load(Some(store_path.clone()));
        let now = Utc::now();
        store.add(&project.to_string_lossy(), "Bash(npm test:*)", Reach::Project, "Codex", now);
        // Duplicate of a Claude file rule adds timestamp/agent metadata without duplicating the row.
        store.add(&project.to_string_lossy(), "Edit", Reach::Project, "Claude Code", now);

        let all = store.list(Some(&project.to_string_lossy()), &[], Some(&home));
        let rules: Vec<(&str, &str)> = all.iter().map(|e| (e.rule.as_str(), e.reach.as_str())).collect();
        assert_eq!(
            rules,
            vec![
                ("Bash(git status:*)", "project"),
                ("Bash(npm test:*)", "project"),
                ("Edit", "project"),
                ("Read", "sharedProject"),
                ("WebSearch", "user"),
            ]
        );
        // Revoke one rule from Claude's local settings file.
        assert!(store.revoke(&project.to_string_lossy(), "Edit", Some(&local_file.to_string_lossy())).unwrap());
        let after = store.list(Some(&project.to_string_lossy()), &[], Some(&home));
        assert!(!after.iter().any(|e| e.rule == "Edit"));
        let disk: Value = serde_json::from_slice(&std::fs::read(&local_file).unwrap()).unwrap();
        assert_eq!(disk["permissions"]["allow"], json!(["Bash(git status:*)"]));

        // Revoke all rules for the project leaves user-level rule untouched.
        let count = store.revoke_project(&project.to_string_lossy()).unwrap();
        assert!(count >= 2);
        let remaining = store.list(Some(&project.to_string_lossy()), &[], Some(&home));
        assert_eq!(remaining.iter().map(|e| e.rule.as_str()).collect::<Vec<_>>(), vec!["WebSearch"]);

        // Persisted store round-trips cleanly.
        let reloaded = GrantedRulesStore::load(Some(store_path));
        assert!(reloaded.projects().is_empty());

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn approval_audit_formats_like_macos_and_stays_bounded() {
        let now = Utc::now();
        let entry = ApprovalAuditEntry::new(
            "Codex",
            "web",
            "/w/web",
            "Bash",
            "npm test",
            "allow",
            None,
            Some(ApprovalSource::Phone),
            false,
            now,
        );
        assert_eq!(entry.args, "Codex · web · Bash · npm test");
        assert_eq!(entry.result, "allow · phone");

        let long = "x".repeat(1_000);
        let dangerous = ApprovalAuditEntry::new(
            "Claude Code",
            "",
            "",
            "Bash",
            &long,
            "deny",
            None,
            Some(ApprovalSource::Notification),
            true,
            now,
        );
        assert_eq!(dangerous.result, "deny · notification · danger");
        assert!(dangerous.args.ends_with('…'));
        assert!(dangerous.summary.chars().count() == AUDIT_ASKED_LIMIT + 1);
        assert!(!dangerous.args.contains(" ·  · "), "empty fields leave no gap");

        let expired = ApprovalAuditEntry::expired("Gemini CLI", "api", "/w/api", "browser_open", "https://example.com", now);
        assert_eq!(expired.result, "expired");
        assert_eq!(expired.args, "Gemini CLI · api · browser_open · https://example.com");

        // Bounded persistence and search.
        let dir = temp_dir("approval-audit");
        let file = dir.join("agent-approval-audit.json");
        let mut log = ApprovalAuditLog::load(Some(file.clone()));
        for i in 0..(MAX_AUDIT_ENTRIES + 25) {
            log.record(ApprovalAuditEntry::new(
                "Claude Code",
                "nook",
                "/w/nook",
                "Bash",
                &format!("cmd-{i}"),
                "allow",
                None,
                Some(ApprovalSource::App),
                false,
                now,
            ));
        }
        assert_eq!(log.len(), MAX_AUDIT_ENTRIES);
        let newest = log.list(1, None);
        assert_eq!(newest[0].summary, format!("cmd-{}", MAX_AUDIT_ENTRIES + 24));
        let hits = log.list(20, Some("cmd-510"));
        assert_eq!(hits.len(), 1);

        let reloaded = ApprovalAuditLog::load(Some(file));
        assert_eq!(reloaded.len(), MAX_AUDIT_ENTRIES);

        let _ = std::fs::remove_dir_all(&dir);
    }
}
