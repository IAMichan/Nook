//! Van sessies naar wat de telefoon ziet (`CompanionServer.digests` op de Mac): sessies die Nook draait en
//! sessies die via hooks binnenkomen. Inkorten, sorteren en begrenzen doet de server.

use serde_json::Value;

use super::backend::BackendSession;
use super::models::{CompanionPolicy, DigestItem, ItemKind, SessionDigest};
use crate::agents::hub::command_text;
use crate::agents::models::{AgentSession, AgentStatus, ApprovalRequest, QuestionItem, QuestionRequest};
use crate::agents::risk::{self, RiskLevel};
use crate::workspace::attention::{AgentAttention, AttentionInput};
use crate::workspace::manager::{PendingPermission, PendingQuestion};
use crate::workspace::models::WorkspaceRun;

/// Sessies van de hub hebben dit voorvoegsel; sessies die Nook draait zijn hun eigen id (een UUID).
pub const HUB_PREFIX: &str = "hub:";

/// Het laatste onderdeel van een pad, ook met backslashes (Windows).
pub fn folder(path: &str) -> String {
    path.trim_end_matches(['/', '\\']).rsplit(['/', '\\']).next().unwrap_or_default().to_string()
}

/// Mag de telefoon dit toestaan? Een commando alleen als het veilig is (`CommandRisk`).
pub fn can_allow(tool: &str, command: Option<&str>) -> bool {
    CompanionPolicy::can_allow(tool, command.map(|c| risk::assess(c).level == RiskLevel::Safe))
}

fn approval_item(id: &str, tool: &str, summary: &str, command: Option<&str>) -> DigestItem {
    DigestItem {
        id: id.into(),
        kind: ItemKind::Approval,
        title: summary.into(),
        detail: tool.into(),
        can_allow: can_allow(tool, command),
        options: vec![],
    }
}

fn question_item(id: &str, items: &[QuestionItem]) -> DigestItem {
    let first = items.first();
    let single = items.len() == 1;
    DigestItem {
        id: id.into(),
        kind: ItemKind::Question,
        title: first.map(|q| q.question.clone()).unwrap_or_default(),
        detail: first.map(|q| q.header.clone()).unwrap_or_default(),
        can_allow: single,
        options: if single { first.map(|q| q.options.iter().map(|o| o.label.clone()).collect()).unwrap_or_default() } else { vec![] },
    }
}

fn seconds(date: Option<chrono::DateTime<chrono::Utc>>) -> f64 {
    date.map(|d| d.timestamp_millis() as f64 / 1000.0).unwrap_or_default()
}

/// Een sessie die Nook zelf draait. Vragen van Claude Code accepteren ook een eigen antwoord ("Other").
pub fn run_session(
    run: &WorkspaceRun,
    approvals: &[PendingPermission],
    questions: &[PendingQuestion],
    last_answer: &str,
) -> BackendSession {
    let attention = AgentAttention::resolve(&AttentionInput {
        status: Some(run.status),
        pending_approvals: approvals.len(),
        pending_questions: questions.len(),
        limited_at: run.limited_at,
        ..Default::default()
    });
    let mut items: Vec<DigestItem> =
        approvals.iter().map(|p| approval_item(&p.id, &p.tool, &p.summary, command_text(&p.input).as_deref())).collect();
    items.extend(questions.iter().map(|q| question_item(&q.id, &q.items)));
    BackendSession {
        digest: SessionDigest {
            id: run.id.to_string(),
            title: run.title.clone(),
            agent: run.provider.display_name().into(),
            attention: attention.raw().into(),
            folder: folder(&run.working_directory),
            branch: run.branch.clone().filter(|b| !b.is_empty()),
            updated: seconds(Some(run.updated_at)),
            excerpt: last_answer.into(),
            items,
        },
        active: run.status.is_active(),
        free_answers: questions.iter().map(|q| q.id.clone()).collect(),
    }
}

/// Mag de telefoon een verzoek via hooks toestaan? Bij een commando is de samenvatting het commando zelf.
pub fn hub_can_allow(request: &ApprovalRequest) -> bool {
    let command = matches!(request.tool.as_str(), "Bash" | "bash" | "shell" | "command" | "Shell").then_some(request.summary.as_str());
    can_allow(&request.tool, command)
}

/// Een sessie in een terminal of editor, via hooks. Ook daar accepteert AskUserQuestion een eigen antwoord.
pub fn hub_session(session: &AgentSession, approvals: &[ApprovalRequest], questions: &[QuestionRequest]) -> BackendSession {
    let approvals: Vec<&ApprovalRequest> = approvals.iter().filter(|a| a.session_key == session.id).collect();
    let questions: Vec<&QuestionRequest> = questions.iter().filter(|q| q.session_key == session.id).collect();
    let attention = if !approvals.is_empty() {
        AgentAttention::Approval
    } else if !questions.is_empty() || session.status == AgentStatus::Waiting {
        AgentAttention::Input
    } else {
        match session.status {
            AgentStatus::Running => AgentAttention::Working,
            AgentStatus::Failed => AgentAttention::Failed,
            _ => AgentAttention::Idle,
        }
    };
    let mut items: Vec<DigestItem> =
        approvals.iter().map(|a| DigestItem { can_allow: hub_can_allow(a), ..approval_item(&a.id, &a.tool, &a.summary, None) }).collect();
    items.extend(questions.iter().map(|q| question_item(&q.id, &q.items)));
    // Zoals de lijst in de tab Agents: de samenvatting, anders je laatste opdracht, anders het project.
    let title = [&session.summary, &session.last_prompt, &session.project, &session.name]
        .into_iter()
        .map(|t| t.lines().next().unwrap_or_default().trim())
        .find(|t| !t.is_empty())
        .unwrap_or_default()
        .to_string();
    BackendSession {
        digest: SessionDigest {
            id: format!("{HUB_PREFIX}{}", session.id),
            title,
            agent: session.name.clone(),
            attention: attention.raw().into(),
            folder: folder(&session.cwd),
            branch: None,
            updated: seconds(session.updated.or(session.started)),
            excerpt: session.last_reply.clone(),
            items,
        },
        active: matches!(session.status, AgentStatus::Running | AgentStatus::Waiting),
        free_answers: questions.iter().map(|q| q.id.clone()).collect(),
    }
}

/// Zoals [`can_allow`], maar rechtstreeks uit de invoer van de tool (voor een melding).
pub fn can_allow_input(tool: &str, input: &Value) -> bool {
    can_allow(tool, command_text(input).as_deref())
}

#[cfg(test)]
mod tests {
    use chrono::Utc;
    use serde_json::json;
    use uuid::Uuid;

    use super::*;
    use crate::agents::models::QuestionOption;
    use crate::workspace::models::RunStatus;

    fn run(status: RunStatus) -> WorkspaceRun {
        let mut run = crate::workspace::models::tests::run(status);
        run.working_directory = "/home/m/code/nook".into();
        run.branch = Some("main".into());
        run
    }

    fn permission(tool: &str, input: serde_json::Value) -> PendingPermission {
        PendingPermission {
            id: "r1".into(),
            run_id: Uuid::new_v4(),
            tool: tool.into(),
            summary: "rm -rf build".into(),
            input,
            suggestions: None,
            event_id: Uuid::new_v4(),
            created: Utc::now(),
        }
    }

    fn question(n: usize) -> PendingQuestion {
        let item = QuestionItem {
            question: "Welke database?".into(),
            header: "Opslag".into(),
            options: vec![
                QuestionOption { label: "SQLite".into(), description: String::new() },
                QuestionOption { label: "Postgres".into(), description: String::new() },
            ],
            multi_select: false,
        };
        PendingQuestion { id: "q1".into(), run_id: Uuid::new_v4(), items: vec![item; n], input: json!({}), created: Utc::now() }
    }

    #[test]
    fn a_run_waiting_for_a_command() {
        let s = run_session(&run(RunStatus::WaitingApproval), &[permission("Bash", json!({"command": "rm -rf build"}))], &[], "Klaar");
        assert_eq!(s.digest.attention, "approval");
        assert_eq!(s.digest.folder, "nook");
        assert_eq!(s.digest.branch.as_deref(), Some("main"));
        assert_eq!(s.digest.agent, "Claude Code");
        assert!(s.active);
        let item = &s.digest.items[0];
        assert_eq!((item.kind, item.title.as_str(), item.detail.as_str()), (ItemKind::Approval, "rm -rf build", "Bash"));
        // Een gevaarlijk commando kan alleen op de computer worden toegestaan; een veilig wel vanaf de telefoon.
        assert!(!item.can_allow);
        let safe = run_session(&run(RunStatus::WaitingApproval), &[permission("Bash", json!({"command": "ls"}))], &[], "");
        assert!(safe.digest.items[0].can_allow);
        let edit = run_session(&run(RunStatus::WaitingApproval), &[permission("Edit", json!({"file_path": "a.rs"}))], &[], "");
        assert!(edit.digest.items[0].can_allow);
        let web = run_session(&run(RunStatus::WaitingApproval), &[permission("WebFetch", json!({"url": "https://x"}))], &[], "");
        assert!(!web.digest.items[0].can_allow);
    }

    #[test]
    fn questions_with_one_or_more_parts() {
        let one = run_session(&run(RunStatus::Running), &[], &[question(1)], "");
        assert_eq!(one.digest.attention, "input");
        let item = &one.digest.items[0];
        assert_eq!((item.title.as_str(), item.detail.as_str()), ("Welke database?", "Opslag"));
        assert!(item.can_allow);
        assert_eq!(item.options, vec!["SQLite", "Postgres"]);
        assert_eq!(one.free_answers, vec!["q1"]);
        let two = run_session(&run(RunStatus::Running), &[], &[question(2)], "");
        assert!(!two.digest.items[0].can_allow);
        assert!(two.digest.items[0].options.is_empty());
    }

    #[test]
    fn finished_runs() {
        let mut limited = run(RunStatus::Failed);
        limited.limited_at = Some(Utc::now());
        assert_eq!(run_session(&limited, &[], &[], "").digest.attention, "limited");
        let done = run_session(&run(RunStatus::Completed), &[], &[], "Alles groen.");
        assert_eq!((done.digest.attention.as_str(), done.digest.excerpt.as_str(), done.active), ("idle", "Alles groen.", false));
        assert_eq!(folder("C:\\Users\\m\\site\\"), "site");
    }

    #[test]
    fn a_hub_session_waiting_in_a_terminal() {
        let session: AgentSession = serde_json::from_value(json!({
            "id": "claude-code:s1", "name": "Claude Code", "project": "nook", "status": "waiting", "file": "", "placeholder": "",
            "steps": [], "diff": [], "cwd": "/w/nook", "host": "", "home": "", "approvalId": null, "questionId": null,
            "linesAdded": 0, "linesRemoved": 0, "summary": "", "isLinked": false, "sessionId": "s1", "transcriptPath": "",
            "lastPrompt": "Schrijf de tests\nvoor de login", "lastReply": "Bijna klaar", "started": null, "updated": null, "pid": null
        }))
        .unwrap();
        let approval: ApprovalRequest = serde_json::from_value(json!({
            "id": "a1", "sessionKey": "claude-code:s1", "agentName": "Claude Code", "project": "nook", "tool": "Bash",
            "summary": "git status", "diff": [], "assessment": {"level": "review", "title": "", "note": ""}, "canAlways": false,
            "created": Utc::now()
        }))
        .unwrap();
        let other = ApprovalRequest { id: "a2".into(), session_key: "codex:x".into(), ..approval.clone() };
        let s = hub_session(&session, &[approval, other], &[]);
        assert_eq!(s.digest.id, "hub:claude-code:s1");
        assert_eq!(s.digest.title, "Schrijf de tests");
        assert_eq!((s.digest.attention.as_str(), s.digest.folder.as_str(), s.digest.excerpt.as_str()), ("approval", "nook", "Bijna klaar"));
        assert_eq!(s.digest.items.len(), 1);
        assert!(s.digest.items[0].can_allow, "git status is veilig");
        assert!(s.active);
    }
}
