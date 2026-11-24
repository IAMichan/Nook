//! What a toast says and offers, as the Mac's `SystemNotifier` rules and `BannerTextTests` describe it.

use super::*;
use crate::agents::line_diff::DiffLine;
use crate::agents::models::ApprovalOrigin;

fn approval(tool: &str, command: &str) -> AgentApproval {
    AgentApproval {
        id: "hook-1".into(),
        origin: ApprovalOrigin::Hook { request_id: "1".into() },
        agent_name: "Claude Code".into(),
        project: "nook".into(),
        tool: tool.into(),
        title: "Claude Code wants to run a command".into(),
        command: command.into(),
        diff: vec![],
        note: String::new(),
        danger: false,
        can_always: false,
        can_terminal: true,
        session_key: "s".into(),
        created: chrono::Utc::now(),
        always_scope: None,
    }
}

fn actions(toast: &Toast) -> Vec<ToastAction> {
    toast.kind.buttons().into_iter().map(|(a, _)| a).collect()
}

#[test]
fn a_short_command_is_allowed_from_the_toast() {
    let toast = Toast::approval(&approval("Bash", "npm test"), "Claude Code · Fix guard", NoticeTarget::Agent("s".into()));
    assert_eq!(toast.kind, ToastKind::Approval);
    assert_eq!(actions(&toast), [ToastAction::Allow, ToastAction::Deny]);
    assert_eq!(toast.body, "npm test");
    assert_eq!(toast.subtitle, "Fix guard", "the title already names the agent");
    assert_eq!(toast.level, ToastLevel::TimeSensitive);

    let always = Toast::approval(&AgentApproval { can_always: true, ..approval("Bash", "npm test") }, "", NoticeTarget::Agents);
    assert_eq!(actions(&always), [ToastAction::Allow, ToastAction::Deny, ToastAction::Always]);
}

#[test]
fn what_does_not_fit_gets_show() {
    let long = format!("npm run build && {}", "x".repeat(250));
    let toast = Toast::approval(&approval("Bash", &long), "", NoticeTarget::Agents);
    assert_eq!(toast.kind, ToastKind::Review);
    assert_eq!(actions(&toast), [ToastAction::Allow, ToastAction::Show, ToastAction::Deny]);
    assert!(toast.body.chars().count() <= 120 && toast.body.ends_with('…'));

    let edit = AgentApproval { diff: vec![DiffLine::context("a")], ..approval("Edit", "Edit src/main.rs") };
    assert_eq!(Toast::approval(&edit, "", NoticeTarget::Agents).kind, ToastKind::Review, "a diff needs a look");
    let mcp = approval("mcp__github__create_pull_request", "Open a pull request");
    assert_eq!(Toast::approval(&mcp, "", NoticeTarget::Agents).kind, ToastKind::Review, "an MCP tool needs a look");
}

#[test]
fn a_dangerous_command_is_never_allowed_unseen() {
    let toast = Toast::approval(&AgentApproval { danger: true, ..approval("Bash", "rm -rf build") }, "", NoticeTarget::Agents);
    assert_eq!(toast.kind, ToastKind::Danger);
    assert_eq!(actions(&toast), [ToastAction::Show, ToastAction::Deny]);
    assert_eq!(toast.body, "rm -rf build\nLook at this in Nook before you allow it.");
    assert!(!toast.windows_xml().contains("action=allow"));
}

#[test]
fn notices_get_the_buttons_their_source_offers() {
    let n = |o: NoticeOptions| Toast::notice("w", "Anna", "", "Hi", NoticeTarget::Chat("whatsapp#anna".into()), ToastLevel::Active, o).kind;
    assert_eq!(n(NoticeOptions::default()), ToastKind::Notice);
    assert_eq!(n(NoticeOptions { reply: true, read: true, app: None }), ToastKind::ChatReply);
    assert_eq!(n(NoticeOptions { reply: true, ..Default::default() }), ToastKind::Reply);
    assert_eq!(n(NoticeOptions { read: true, ..Default::default() }), ToastKind::Chat);
    assert_eq!(n(NoticeOptions { app: Some("Open Terminal".into()), ..Default::default() }), ToastKind::App("Open Terminal".into()));
}

#[test]
fn toasts_are_grouped_per_chat_and_session() {
    let run = Uuid::nil();
    assert_eq!(NoticeTarget::Agent("abc".into()).thread(), "agent:abc");
    assert_eq!(NoticeTarget::Run(run).thread(), format!("agent:run:{run}"));
    assert_eq!(NoticeTarget::Chat("whatsapp#anna".into()).thread(), "chat:whatsapp#anna");
    assert_eq!(NoticeTarget::Conversation(run).thread(), "nook");
    let toast =
        Toast::notice(&"x".repeat(100), "t", "", "", NoticeTarget::Chat("y".repeat(100)), ToastLevel::Active, NoticeOptions::default());
    assert!(toast.tag().chars().count() <= TAG_LIMIT && toast.group().chars().count() <= TAG_LIMIT, "Windows' 64-character limit");
    let other = Toast { id: format!("{}z", "x".repeat(99)), ..toast.clone() };
    assert_ne!(toast.tag(), other.tag(), "long ids stay apart");
}

#[test]
fn a_click_survives_a_restart() {
    let id = Uuid::new_v4();
    for target in [
        NoticeTarget::Agent("claude:abc & co".into()),
        NoticeTarget::Run(id),
        NoticeTarget::Agents,
        NoticeTarget::Conversation(id),
        NoticeTarget::Chat("whatsapp#31612345678@s.whatsapp.net".into()),
        NoticeTarget::Nowhere,
    ] {
        let link = ToastLink { toast: "hook-1".into(), action: ToastAction::Deny, target };
        assert_eq!(ToastLink::parse(&link.to_url()).as_ref(), Some(&link));
    }
    let args = vec![
        "C:\\Program Files\\Nook\\nook.exe".to_string(),
        ToastLink { toast: "t".into(), action: ToastAction::Open, target: NoticeTarget::Conversation(id) }.to_url(),
    ];
    let link = ToastLink::from_args(&args).unwrap();
    assert_eq!(link.target.route(), format!("nook:{id}"));
    assert!(ToastLink::parse("https://notice?toast=1").is_none());
    assert!(ToastLink::parse("nook://other").is_none());
    assert_eq!(ToastLink::parse("nook://notice?target=run&id=bad").unwrap().target, NoticeTarget::Agents);
}

#[test]
fn windows_xml_escapes_and_links() {
    let toast = Toast::notice(
        "chat-1",
        "Anna & <Co>",
        "WhatsApp",
        "\"Hi\" it's me",
        NoticeTarget::Chat("whatsapp#anna".into()),
        ToastLevel::Active,
        NoticeOptions { reply: true, read: true, app: None },
    );
    let xml = toast.windows_xml();
    assert!(xml.starts_with(
        "<toast launch=\"nook://notice?toast=chat-1&amp;action=open&amp;target=chat&amp;id=whatsapp%23anna\" activationType=\"protocol\">"
    ));
    assert!(xml.contains("<text>Anna &amp; &lt;Co&gt;</text><text>WhatsApp</text><text>\"Hi\" it's me</text>"));
    assert!(xml.contains("<input id=\"reply\" type=\"text\" placeHolderContent=\"Type a reply…\"/>"));
    assert!(xml.contains("content=\"Send\" arguments=\"nook://notice?toast=chat-1&amp;action=reply"));
    assert!(xml.contains("activationType=\"foreground\" hint-inputId=\"reply\"/>"));
    assert!(xml.contains("content=\"Mark as read\""));
    assert!(xml.ends_with("<audio silent=\"true\"/></toast>"), "Nook plays its own sounds");

    let plain = Toast::notice("n", "Done", "", "", NoticeTarget::Nowhere, ToastLevel::Passive, NoticeOptions::default()).windows_xml();
    assert!(!plain.contains("<actions>") && !plain.contains("<text></text>"));
}

// MARK: Banner text (BannerTextTests)

#[test]
fn a_long_reply_becomes_its_first_sentence() {
    let reply = "The branch is pushed and PR #1394 is now at d3f92455. CI has started again; the run takes about 10 minutes because chatd builds first.";
    assert_eq!(banner::gist(reply, banner::LIMIT), "The branch is pushed and PR #1394 is now at d3f92455.");
}

#[test]
fn links_and_markdown_are_shortened() {
    assert_eq!(
        banner::gist("PR 6 is klaar: https://github.com/InfarisHQ/monorepo/pull/3885 (verdwaalde rondingen).", banner::LIMIT),
        "PR 6 is klaar: #3885 (verdwaalde rondingen)."
    );
    assert_eq!(
        banner::gist("See [the docs](https://example.com/a/b) and https://www.apple.com/mac for more.", banner::LIMIT),
        "See the docs and apple.com for more."
    );
    assert_eq!(banner::gist("## Summary\n\n- **Fixed** the `login` bug", banner::LIMIT), "Summary");
    assert_eq!(banner::plain("- **Fixed** the `login` bug"), "Fixed the login bug");
}

#[test]
fn a_short_first_sentence_takes_the_next_along() {
    assert_eq!(banner::gist("Done. All 42 tests pass now. Nothing else.", banner::LIMIT), "Done. All 42 tests pass now.");
}

#[test]
fn the_gist_stays_within_the_limit() {
    let gist = banner::gist(&"word ".repeat(60), banner::LIMIT);
    assert!(gist.chars().count() <= banner::LIMIT);
    assert!(gist.ends_with('…'));
}

#[test]
fn the_subtitle_names_folder_and_session() {
    assert_eq!(banner::subtitle("nook", "Fix the login bug"), "nook · Fix the login bug");
    assert_eq!(banner::subtitle("nook", ""), "nook");
    assert!(banner::subtitle("", &"a ".repeat(80)).chars().count() <= banner::SUBTITLE_LIMIT);
}

#[test]
fn an_approvals_context_drops_the_agent_the_title_names() {
    assert_eq!(banner::context("Claude Code · Fix guard", "Claude Code wants to open a pull request"), "Fix guard");
    assert_eq!(banner::context("Codex · nook", "Run a command"), "Codex · nook");
}

#[test]
fn an_agent_notice_says_who_where_and_the_gist() {
    let mut session = AgentSession {
        id: format!("run:{}", Uuid::nil()),
        name: "Claude Code".into(),
        project: "Push the branch".into(),
        status: AgentStatus::Done,
        file: String::new(),
        placeholder: String::new(),
        steps: vec![],
        diff: vec![],
        cwd: "/home/jo/nook".into(),
        host: String::new(),
        home: String::new(),
        approval_id: None,
        question_id: None,
        lines_added: 0,
        lines_removed: 0,
        summary: "Pushed. CI runs again and takes about ten minutes. More follows.".into(),
        is_linked: false,
        session_id: String::new(),
        transcript_path: String::new(),
        last_prompt: String::new(),
        last_reply: String::new(),
        started: None,
        updated: None,
        pid: None,
        launched_by: None,
    };
    let toast = Toast::agent_status(&session).unwrap();
    assert_eq!(toast.title, "Claude Code is done");
    assert_eq!(toast.subtitle, "nook · Push the branch");
    assert_eq!(toast.body, "Pushed. CI runs again and takes about ten minutes.");
    assert_eq!(toast.target, NoticeTarget::Run(Uuid::nil()));
    assert_eq!(toast.kind, ToastKind::Reply, "a session Nook runs takes an answer from the toast");

    session.status = AgentStatus::Waiting;
    session.project = "nook".into();
    let waiting = Toast::agent_status(&session).unwrap();
    assert_eq!((waiting.level, waiting.subtitle.as_str()), (ToastLevel::TimeSensitive, "nook"), "the folder once");
    session.status = AgentStatus::Running;
    assert!(Toast::agent_status(&session).is_none());
}
