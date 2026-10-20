//! Wat Nook van een agentsessie weet (`AgentSession`, `AgentModels` op de Mac): status, stappen, toestemmingsvragen,
//! meerkeuzevragen en het abonnementsgebruik uit de statusregel van Claude Code.

use chrono::{DateTime, TimeZone, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};

use super::line_diff::DiffLine;
use super::risk::{CommandAssessment, RiskLevel};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AgentStatus {
    Waiting,
    Running,
    Failed,
    Done,
    /// Draait op deze computer, maar nog niet gekoppeld met hooks.
    Detected,
}

impl AgentStatus {
    pub fn label(self) -> &'static str {
        match self {
            Self::Detected => "gezien",
            Self::Waiting => "wacht op jou",
            Self::Running => "bezig",
            Self::Failed => "mislukt",
            Self::Done => "klaar",
        }
    }

    pub fn order(self) -> u8 {
        match self {
            Self::Waiting => 0,
            Self::Failed => 1,
            Self::Running => 2,
            Self::Done => 3,
            Self::Detected => 9,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum StepMark {
    Done,
    Running,
    Blocked,
    Failed,
    Todo,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgentStep {
    pub mark: StepMark,
    pub text: String,
}

impl AgentStep {
    pub fn new(mark: StepMark, text: impl Into<String>) -> Self {
        Self { mark, text: text.into() }
    }
}

/// Een agentsessie zoals de interface hem toont.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentSession {
    pub id: String,
    pub name: String,
    pub project: String,
    pub status: AgentStatus,
    pub file: String,
    pub placeholder: String,
    pub steps: Vec<AgentStep>,
    pub diff: Vec<DiffLine>,
    pub cwd: String,
    /// De app waarin de agent draait (Windows Terminal, VS Code, …), voor "Open terminal".
    pub host: String,
    /// De accountmap (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`); leeg voor het standaardaccount.
    pub home: String,
    pub approval_id: Option<String>,
    pub question_id: Option<String>,
    pub lines_added: usize,
    pub lines_removed: usize,
    /// Eén zin uit het laatste antwoord van de agent.
    pub summary: String,
    /// Alleen bij gevonden processen: de agent is gekoppeld, maar deze sessie startte daarvoor.
    pub is_linked: bool,
    pub session_id: String,
    pub transcript_path: String,
    pub last_prompt: String,
    pub last_reply: String,
    pub started: Option<DateTime<Utc>>,
    pub updated: Option<DateTime<Utc>>,
    /// Het proces achter een gevonden sessie.
    pub pid: Option<u32>,
}

impl AgentSession {
    pub fn is_detected(&self) -> bool {
        self.status == AgentStatus::Detected
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ApprovalDecision {
    /// Deze keer.
    Allow,
    /// En onthouden (Claude Code bewaart de regel zelf).
    Always,
    Deny,
    /// Niet hier: de agent vraagt het in zijn eigen venster.
    Terminal,
}

/// Een agent vraagt toestemming. Nook toont hem; de keuze gaat terug via de hub.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ApprovalRequest {
    pub id: String,
    pub session_key: String,
    pub agent_name: String,
    pub project: String,
    pub tool: String,
    /// Het commando of een korte omschrijving: nooit ingekort, want wat je toestaat is wat je zag.
    pub summary: String,
    pub diff: Vec<DiffLine>,
    pub assessment: CommandAssessment,
    pub can_always: bool,
    pub created: DateTime<Utc>,
}

impl ApprovalRequest {
    pub fn title(&self) -> String {
        if self.assessment.level == RiskLevel::Danger {
            return self.assessment.title.clone();
        }
        approval_title(&self.agent_name, &self.tool)
    }
}

/// "Mag Claude Code dit uitvoeren?"
pub fn approval_title(agent: &str, tool: &str) -> String {
    // An MCP tool by its readable name and server: "Claude Code wil “Move file” van Bestanden mappen gebruiken".
    if let Some(mcp) = super::mcp_name::McpToolName::parse(tool) {
        return format!("{agent} wil “{}” van {} gebruiken", mcp.tool_label(), mcp.server_label());
    }
    match tool {
        "Bash" | "shell" | "run_shell_command" | "exec_command" => format!("Mag {agent} dit uitvoeren?"),
        "Edit" | "MultiEdit" | "Write" | "NotebookEdit" | "write_file" | "replace" | "apply_patch" => {
            format!("Mag {agent} dit bestand aanpassen?")
        }
        "WebFetch" | "web_fetch" => format!("Mag {agent} deze pagina ophalen?"),
        "WebSearch" | "google_web_search" => format!("Mag {agent} op het web zoeken?"),
        t => format!("Mag {agent} {t} gebruiken?"),
    }
}

/// Waar een toestemmingsvraag vandaan kwam (`ApprovalCenter` op de Mac): een hook van een sessie in een terminal, een
/// sessie die Nook zelf draait, of een verzoek via de werkruimte-brug.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ApprovalOrigin {
    Hook { request_id: String },
    Run { run_id: String, request_id: String },
    Bridge { request_id: String },
}

/// Eén toestemmingsvraag, hoe hij Nook ook bereikte. Elke plek die er een toont of beslist, werkt met dit type.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentApproval {
    pub id: String,
    pub origin: ApprovalOrigin,
    pub agent_name: String,
    pub project: String,
    pub tool: String,
    pub title: String,
    /// Het hele commando of de hele omschrijving, nooit ingekort.
    pub command: String,
    pub diff: Vec<DiffLine>,
    pub note: String,
    pub danger: bool,
    pub can_always: bool,
    /// De agent kan het ook in zijn eigen terminal vragen (alleen bij hooks).
    pub can_terminal: bool,
    pub session_key: String,
    pub created: DateTime<Utc>,
}

impl AgentApproval {
    pub fn from_hook(r: &ApprovalRequest) -> Self {
        Self {
            id: format!("hook-{}", r.id),
            origin: ApprovalOrigin::Hook { request_id: r.id.clone() },
            agent_name: r.agent_name.clone(),
            project: r.project.clone(),
            tool: r.tool.clone(),
            title: r.title(),
            command: r.summary.clone(),
            diff: r.diff.clone(),
            note: r.assessment.note.clone(),
            danger: r.assessment.level == RiskLevel::Danger,
            can_always: r.can_always,
            can_terminal: true,
            session_key: r.session_key.clone(),
            created: r.created,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct QuestionOption {
    pub label: String,
    pub description: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuestionItem {
    pub question: String,
    pub header: String,
    pub options: Vec<QuestionOption>,
    pub multi_select: bool,
}

/// Een agent stelt een meerkeuzevraag (AskUserQuestion). Nook toont de vragen na elkaar.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuestionRequest {
    pub id: String,
    pub session_key: String,
    pub agent_name: String,
    pub project: String,
    pub items: Vec<QuestionItem>,
}

impl QuestionRequest {
    /// Leest `tool_input` van AskUserQuestion. `None` als de vorm niet klopt.
    pub fn parse(input: &Value) -> Option<Vec<QuestionItem>> {
        let raw = input.get("questions")?.as_array()?;
        if raw.is_empty() || raw.len() > 4 {
            return None;
        }
        let mut items = Vec::new();
        for entry in raw {
            let question = entry.get("question")?.as_str().filter(|q| !q.is_empty())?;
            let options = entry.get("options")?.as_array()?;
            if !(2..=6).contains(&options.len()) {
                return None;
            }
            let mut parsed = Vec::new();
            for option in options {
                let label = option.get("label")?.as_str().filter(|l| !l.is_empty())?;
                let description = option.get("description").and_then(Value::as_str).unwrap_or("");
                parsed.push(QuestionOption { label: label.into(), description: description.into() });
            }
            let header: String = entry.get("header").and_then(Value::as_str).unwrap_or("").chars().take(16).collect();
            items.push(QuestionItem {
                question: question.into(),
                header,
                options: parsed,
                multi_select: entry.get("multiSelect").and_then(Value::as_bool).unwrap_or(false),
            });
        }
        Some(items)
    }

    /// De antwoorden voor Claude Code: vraag → gekozen label (of lijst bij meerdere keuzes).
    pub fn answers(items: &[QuestionItem], selections: &[Vec<String>]) -> Value {
        let mut result = Map::new();
        for (item, chosen) in items.iter().zip(selections) {
            if item.multi_select {
                result.insert(item.question.clone(), json!(chosen));
            } else if let Some(first) = chosen.first() {
                result.insert(item.question.clone(), json!(first));
            }
        }
        Value::Object(result)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanWindow {
    pub used_percent: f64,
    pub resets_at: DateTime<Utc>,
}

impl PlanWindow {
    /// Na de resettijd is het gebruik weer nul.
    pub fn effective_percent(&self, now: DateTime<Utc>) -> f64 {
        if self.resets_at <= now {
            0.0
        } else {
            self.used_percent
        }
    }
}

/// Het gebruik van een Claude-abonnement (Pro/Max), uit de statusregel van Claude Code.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanUsage {
    pub five_hour: Option<PlanWindow>,
    pub seven_day: Option<PlanWindow>,
    pub updated: DateTime<Utc>,
}

impl PlanUsage {
    pub fn parse(event: &Value, now: DateTime<Utc>) -> Option<Self> {
        let limits = event.get("rate_limits")?;
        let window = |raw: Option<&Value>| -> Option<PlanWindow> {
            let raw = raw?;
            let percent = raw.get("used_percentage")?.as_f64()?;
            if !(0.0..=200.0).contains(&percent) {
                return None;
            }
            let epoch = raw.get("resets_at")?.as_f64()?;
            if epoch <= 0.0 || epoch >= now.timestamp() as f64 + 400.0 * 86_400.0 {
                return None;
            }
            Some(PlanWindow { used_percent: percent.min(100.0), resets_at: Utc.timestamp_opt(epoch as i64, 0).single()? })
        };
        let five = window(limits.get("five_hour"));
        let week = window(limits.get("seven_day"));
        if five.is_none() && week.is_none() {
            return None;
        }
        Some(Self { five_hour: five, seven_day: week, updated: now })
    }

    /// "5u 34% · week 12%"
    pub fn label(&self, now: DateTime<Utc>) -> String {
        let mut parts = vec![];
        if let Some(w) = &self.five_hour {
            parts.push(format!("5u {}%", w.effective_percent(now).round() as i64));
        }
        if let Some(w) = &self.seven_day {
            parts.push(format!("week {}%", w.effective_percent(now).round() as i64));
        }
        parts.join(" · ")
    }

    pub fn highest(&self, now: DateTime<Utc>) -> f64 {
        let f = self.five_hour.as_ref().map(|w| w.effective_percent(now)).unwrap_or(0.0);
        let s = self.seven_day.as_ref().map(|w| w.effective_percent(now)).unwrap_or(0.0);
        f.max(s)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_questions() {
        let input = json!({"questions": [{"question": "Welke?", "header": "Een heel lange kop van meer dan 16", "options": [
            {"label": "A", "description": "eerste"}, {"label": "B"}], "multiSelect": true}]});
        let items = QuestionRequest::parse(&input).unwrap();
        assert_eq!(items[0].header.chars().count(), 16);
        assert!(items[0].multi_select);
        assert_eq!(items[0].options[1].description, "");
        let answers = QuestionRequest::answers(&items, &[vec!["A".into(), "B".into()]]);
        assert_eq!(answers, json!({"Welke?": ["A", "B"]}));
    }

    #[test]
    fn rejects_bad_questions() {
        assert!(QuestionRequest::parse(&json!({"questions": []})).is_none());
        assert!(QuestionRequest::parse(&json!({"questions": [{"question": "x", "options": [{"label": "a"}]}]})).is_none());
    }

    #[test]
    fn plan_usage_from_statusline() {
        let now = Utc::now();
        let reset = now.timestamp() + 3600;
        let event = json!({"rate_limits": {"five_hour": {"used_percentage": 34.2, "resets_at": reset},
            "seven_day": {"used_percentage": 12, "resets_at": reset + 86400}}});
        let usage = PlanUsage::parse(&event, now).unwrap();
        assert_eq!(usage.label(now), "5u 34% · week 12%");
        assert!(PlanUsage::parse(&json!({"rate_limits": {"five_hour": {"used_percentage": 500, "resets_at": reset}}}), now).is_none());
    }

    #[test]
    fn approval_titles() {
        assert_eq!(approval_title("Codex", "exec_command"), "Mag Codex dit uitvoeren?");
        assert_eq!(approval_title("Claude Code", "mcp__github__search_issues"), "Claude Code wil “Search issues” van Github gebruiken");
    }
}
