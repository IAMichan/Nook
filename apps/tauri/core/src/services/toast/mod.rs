//! What a system notification (a Windows toast) says and offers: the port of the Mac's `SystemNotifier` rules and
//! `BannerText`. Platform code only shows what this decides.
//!
//! - A permission request whose whole command fits on the toast gets Allow and Deny (and Always when the agent offers
//!   it). One you cannot fully see there (a long command, a file edit's diff, an MCP tool) gets Allow, Show and Deny: the
//!   toast says what it is about, Show opens it in full. A dangerous command only gets Show and Deny, so it is never
//!   allowed without being seen.
//! - Notices are grouped per chat and per agent session, chats can be answered and marked read on the toast.
//! - A click on the toast itself is a `nook://notice` link with its target in it, so it still opens the right place
//!   after Nook restarted. Buttons need the running Nook that posted them; after a restart they only open the target.

use uuid::Uuid;

use crate::agents::mcp_name::McpToolName;
use crate::agents::models::{AgentApproval, AgentSession, AgentStatus};
use crate::i18n::{tr, trf};

/// The longest command that may be allowed straight from a toast; longer ones are opened in Nook first.
pub const BANNER_LIMIT: usize = 200;
/// Notices (not approvals) kept clickable by their buttons; older ones lose their handler, so ignored toasts do not pile up.
pub const NOTICE_LIMIT: usize = 20;
/// Windows limits a toast's tag and group to 64 characters.
pub const TAG_LIMIT: usize = 64;

// MARK: Target

/// Where a click on a notice takes you (`NoticeEntry.Target` on the Mac): a value, so a toast never holds on to what
/// made it, and kept in the toast's link.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NoticeTarget {
    /// An agent session in the Agents tab, by its id.
    Agent(String),
    /// A session Nook runs itself, by its run id.
    Run(Uuid),
    /// The Agents tab, without a session chosen.
    Agents,
    /// A conversation with Nook.
    Conversation(Uuid),
    /// A chat in the Chats tab, by its id there ("whatsapp#<chat key>").
    Chat(String),
    /// Nothing to open.
    Nowhere,
}

impl NoticeTarget {
    /// The group in the notification center: one per chat and per agent session.
    pub fn thread(&self) -> String {
        match self {
            NoticeTarget::Agent(id) => format!("agent:{id}"),
            NoticeTarget::Run(id) => format!("agent:run:{id}"),
            NoticeTarget::Agents => "agents".into(),
            NoticeTarget::Conversation(_) => "nook".into(),
            NoticeTarget::Chat(id) => format!("chat:{id}"),
            NoticeTarget::Nowhere => "nook.notice".into(),
        }
    }

    /// The main window's route for it (`show_main`).
    pub fn route(&self) -> String {
        match self {
            NoticeTarget::Agent(_) | NoticeTarget::Run(_) | NoticeTarget::Agents => "agents".into(),
            NoticeTarget::Conversation(id) => format!("nook:{id}"),
            NoticeTarget::Chat(_) => "chats".into(),
            NoticeTarget::Nowhere => "chat".into(),
        }
    }

    fn stored(&self) -> (&'static str, String) {
        match self {
            NoticeTarget::Agent(id) => ("agent", id.clone()),
            NoticeTarget::Run(id) => ("run", id.to_string()),
            NoticeTarget::Agents => ("agents", String::new()),
            NoticeTarget::Conversation(id) => ("conversation", id.to_string()),
            NoticeTarget::Chat(id) => ("chat", id.clone()),
            NoticeTarget::Nowhere => ("nowhere", String::new()),
        }
    }

    fn from_stored(kind: &str, id: &str) -> Self {
        match kind {
            "agent" if !id.is_empty() => NoticeTarget::Agent(id.into()),
            "run" => Uuid::parse_str(id).map(NoticeTarget::Run).unwrap_or(NoticeTarget::Agents),
            "agents" => NoticeTarget::Agents,
            "conversation" => Uuid::parse_str(id).map(NoticeTarget::Conversation).unwrap_or(NoticeTarget::Nowhere),
            "chat" if !id.is_empty() => NoticeTarget::Chat(id.into()),
            _ => NoticeTarget::Nowhere,
        }
    }
}

// MARK: Link

/// What was done on a toast.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ToastAction {
    Open,
    Allow,
    Always,
    Deny,
    Show,
    Reply,
    Read,
    App,
}

impl ToastAction {
    pub fn name(self) -> &'static str {
        match self {
            ToastAction::Open => "open",
            ToastAction::Allow => "allow",
            ToastAction::Always => "always",
            ToastAction::Deny => "deny",
            ToastAction::Show => "show",
            ToastAction::Reply => "reply",
            ToastAction::Read => "read",
            ToastAction::App => "app",
        }
    }

    fn from_name(name: &str) -> Option<Self> {
        [Self::Open, Self::Allow, Self::Always, Self::Deny, Self::Show, Self::Reply, Self::Read, Self::App]
            .into_iter()
            .find(|a| a.name() == name)
    }
}

/// A toast's click or button as a `nook://notice` link: which toast, what was done, and where it leads.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ToastLink {
    pub toast: String,
    pub action: ToastAction,
    pub target: NoticeTarget,
}

pub const SCHEME: &str = "nook";

impl ToastLink {
    pub fn to_url(&self) -> String {
        let (kind, id) = self.target.stored();
        let mut url = url::Url::parse("nook://notice").expect("static url");
        url.query_pairs_mut()
            .append_pair("toast", &self.toast)
            .append_pair("action", self.action.name())
            .append_pair("target", kind)
            .append_pair("id", &id);
        url.to_string()
    }

    /// Reads a link back; None for anything that is not one of Nook's notice links.
    pub fn parse(text: &str) -> Option<Self> {
        let url = url::Url::parse(text.trim()).ok()?;
        if url.scheme() != SCHEME || url.host_str() != Some("notice") {
            return None;
        }
        let get = |key: &str| url.query_pairs().find(|(k, _)| k == key).map(|(_, v)| v.into_owned()).unwrap_or_default();
        Some(Self {
            toast: get("toast"),
            action: ToastAction::from_name(&get("action")).unwrap_or(ToastAction::Open),
            target: NoticeTarget::from_stored(&get("target"), &get("id")),
        })
    }

    /// The link among a program's arguments (Windows starts `nook.exe "<link>"` for a click after a restart).
    pub fn from_args(args: &[String]) -> Option<Self> {
        args.iter().find_map(|a| Self::parse(a))
    }
}

// MARK: Toast

/// How much a toast may interrupt (`UNNotificationInterruptionLevel` on the Mac).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ToastLevel {
    /// What can wait (a suggestion): straight to the notification center, without a popup.
    Passive,
    Active,
    /// What waits on you: high priority, so it leads its group and comes through where Windows lets it.
    TimeSensitive,
}

/// The buttons a toast gets (the Mac's notification categories).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ToastKind {
    /// Allow and Deny.
    Approval,
    /// Allow, Deny and Always.
    ApprovalAlways,
    /// Allow, Show and Deny: too long to see in full on the toast.
    Review,
    /// Show and Deny: dangerous, only decided after a look.
    Danger,
    Notice,
    /// A reply field.
    Reply,
    /// Mark as read.
    Chat,
    /// A reply field and Mark as read.
    ChatReply,
    /// A button that opens where the notice comes from ("Open Terminal").
    App(String),
}

impl ToastKind {
    pub fn is_approval(&self) -> bool {
        matches!(self, ToastKind::Approval | ToastKind::ApprovalAlways | ToastKind::Review | ToastKind::Danger)
    }

    /// The buttons in order, with their labels in the current language. Deny is always on a request's toast.
    pub fn buttons(&self) -> Vec<(ToastAction, String)> {
        let allow = (ToastAction::Allow, tr("Toestaan", "Allow").to_string());
        let always = (ToastAction::Always, tr("Altijd", "Always").to_string());
        let deny = (ToastAction::Deny, tr("Weigeren", "Deny").to_string());
        let show = (ToastAction::Show, tr("Bekijk", "Show").to_string());
        let read = (ToastAction::Read, tr("Markeer als gelezen", "Mark as read").to_string());
        let reply = (ToastAction::Reply, tr("Verstuur", "Send").to_string());
        match self {
            ToastKind::Approval => vec![allow, deny],
            ToastKind::ApprovalAlways => vec![allow, deny, always],
            ToastKind::Review => vec![allow, show, deny],
            ToastKind::Danger => vec![show, deny],
            ToastKind::Notice => vec![],
            ToastKind::Reply => vec![reply],
            ToastKind::Chat => vec![read],
            ToastKind::ChatReply => vec![reply, read],
            ToastKind::App(title) => vec![(ToastAction::App, title.clone())],
        }
    }

    pub fn has_reply(&self) -> bool {
        matches!(self, ToastKind::Reply | ToastKind::ChatReply)
    }
}

/// One toast, ready for the platform to show.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Toast {
    /// A newer toast with the same id replaces the one before; also how it is withdrawn.
    pub id: String,
    pub title: String,
    pub subtitle: String,
    pub body: String,
    pub kind: ToastKind,
    pub level: ToastLevel,
    pub target: NoticeTarget,
    /// The group; from `target` when None.
    pub thread: Option<String>,
}

/// What a notice's toast offers besides the click (`NoticeBanner` on the Mac).
#[derive(Debug, Clone, Default)]
pub struct NoticeOptions {
    pub reply: bool,
    pub read: bool,
    /// The title of an "Open …" button.
    pub app: Option<String>,
}

impl Toast {
    /// Whether a request can be allowed from its toast: the whole command is on it and nothing needs a closer look.
    pub fn can_allow_from_banner(approval: &AgentApproval) -> bool {
        !approval.danger
            && approval.diff.is_empty()
            && McpToolName::parse(&approval.tool).is_none()
            && !approval.command.is_empty()
            && approval.command.chars().count() <= BANNER_LIMIT
    }

    /// A permission request. `context` is who and where ("Claude Code · nook").
    pub fn approval(approval: &AgentApproval, context: &str, target: NoticeTarget) -> Self {
        let (body, kind) = if Self::can_allow_from_banner(approval) {
            (approval.command.clone(), if approval.can_always { ToastKind::ApprovalAlways } else { ToastKind::Approval })
        } else {
            // Too much for a toast: it only says what it is about, Show opens it in full. A dangerous one is only
            // decided after that look.
            let gist = if is_shell_tool(&approval.tool) {
                banner::cut(approval.command.lines().next().unwrap_or(""), 120)
            } else {
                banner::gist(&approval.command, 120)
            };
            let hint = if approval.danger {
                tr("Bekijk dit eerst in Nook voordat je het toestaat.", "Look at this in Nook before you allow it.")
            } else {
                ""
            };
            let body = [gist.as_str(), hint].iter().filter(|t| !t.is_empty()).copied().collect::<Vec<_>>().join("\n");
            (body, if approval.danger { ToastKind::Danger } else { ToastKind::Review })
        };
        Self {
            id: approval.id.clone(),
            title: approval.title.clone(),
            subtitle: banner::context(context, &approval.title),
            body,
            kind,
            level: ToastLevel::TimeSensitive,
            target,
            thread: None,
        }
    }

    /// A notice (an agent is done, failed, asks something; a message came in).
    pub fn notice(
        id: &str,
        title: &str,
        subtitle: &str,
        body: &str,
        target: NoticeTarget,
        level: ToastLevel,
        options: NoticeOptions,
    ) -> Self {
        let kind = match (options.reply, options.read, options.app) {
            (true, true, _) => ToastKind::ChatReply,
            (true, false, _) => ToastKind::Reply,
            (false, true, _) => ToastKind::Chat,
            (false, false, Some(app)) => ToastKind::App(app),
            (false, false, None) => ToastKind::Notice,
        };
        Self { id: id.into(), title: title.into(), subtitle: subtitle.into(), body: body.into(), kind, level, target, thread: None }
    }

    /// An agent that is done, stopped with an error, or waits on you (`AgentStatusNotice` on the Mac): who and what as
    /// the title, folder and topic under it, the gist of what it said last. One per session: a newer one replaces it.
    pub fn agent_status(session: &AgentSession) -> Option<Self> {
        let agent = [("agent", &session.name as &dyn std::fmt::Display)];
        let (title, level) = match session.status {
            AgentStatus::Done => (trf("{agent} is klaar", "{agent} is done", &agent), ToastLevel::Active),
            AgentStatus::Failed => (trf("{agent} is gestopt met een fout", "{agent} stopped with an error", &agent), ToastLevel::Active),
            AgentStatus::Waiting => (trf("{agent} wacht op je", "{agent} is waiting on you", &agent), ToastLevel::TimeSensitive),
            AgentStatus::Running | AgentStatus::Detected => return None,
        };
        let folder = std::path::Path::new(&session.cwd).file_name().map(|f| f.to_string_lossy().into_owned()).unwrap_or_default();
        let topic = if session.project == folder { "" } else { session.project.as_str() };
        let said = if session.summary.trim().is_empty() { &session.last_reply } else { &session.summary };
        let target = match session.id.strip_prefix("run:").map(Uuid::parse_str) {
            Some(Ok(run)) => NoticeTarget::Run(run),
            _ => NoticeTarget::Agent(session.id.clone()),
        };
        // A session Nook runs takes your answer from the toast (`AgentStatusNotice`'s reply); one in a terminal can't.
        let kind = if matches!(target, NoticeTarget::Run(_)) { ToastKind::Reply } else { ToastKind::Notice };
        Some(Self {
            id: format!("agent-notice:{}", session.id),
            title,
            subtitle: banner::subtitle(&folder, topic),
            body: banner::gist(said, banner::LIMIT),
            kind,
            level,
            target,
            thread: None,
        })
    }

    pub fn group(&self) -> String {
        short_tag(&self.thread.clone().unwrap_or_else(|| self.target.thread()))
    }

    pub fn tag(&self) -> String {
        short_tag(&self.id)
    }

    fn link(&self, action: ToastAction) -> String {
        ToastLink { toast: self.id.clone(), action, target: self.target.clone() }.to_url()
    }

    /// The toast as Windows' toast XML. A click on the toast itself is a protocol link (so it works after a restart);
    /// the buttons and the reply field are handled by the running Nook (foreground activation).
    pub fn windows_xml(&self) -> String {
        // How much it interrupts is the toast's priority (`ToastLevel`), set by the platform, not a scenario: a
        // "reminder" would stay on screen, where the Mac's time-sensitive banner goes away by itself.
        let mut xml = format!("<toast launch=\"{}\" activationType=\"protocol\">", attr(&self.link(ToastAction::Open)));
        xml.push_str("<visual><binding template=\"ToastGeneric\">");
        for line in [&self.title, &self.subtitle, &self.body] {
            if !line.is_empty() {
                xml.push_str(&format!("<text>{}</text>", text(line)));
            }
        }
        xml.push_str("</binding></visual>");
        let buttons = self.kind.buttons();
        if !buttons.is_empty() {
            xml.push_str("<actions>");
            if self.kind.has_reply() {
                xml.push_str(&format!(
                    "<input id=\"reply\" type=\"text\" placeHolderContent=\"{}\"/>",
                    attr(tr("Typ een antwoord…", "Type a reply…"))
                ));
            }
            for (action, label) in buttons {
                let input = if action == ToastAction::Reply { " hint-inputId=\"reply\"" } else { "" };
                xml.push_str(&format!(
                    "<action content=\"{}\" arguments=\"{}\" activationType=\"foreground\"{input}/>",
                    attr(&label),
                    attr(&self.link(action))
                ));
            }
            xml.push_str("</actions>");
        }
        // Nook plays its own sounds, so the toast itself stays silent.
        xml.push_str("<audio silent=\"true\"/></toast>");
        xml
    }
}

/// Shell commands are shown by their first line; anything else (a description, a question) by its first sentence.
fn is_shell_tool(tool: &str) -> bool {
    matches!(tool.to_ascii_lowercase().as_str(), "bash" | "shell" | "exec_command" | "run_shell_command" | "terminal" | "powershell")
}

/// Windows allows 64 characters: a longer id keeps its start and a short hash, so it stays unique.
fn short_tag(text: &str) -> String {
    if text.chars().count() <= TAG_LIMIT {
        return text.to_string();
    }
    use sha2::Digest;
    let hash = sha2::Sha256::digest(text.as_bytes());
    let hex: String = hash.iter().take(6).map(|b| format!("{b:02x}")).collect();
    let head: String = text.chars().take(TAG_LIMIT - hex.len() - 1).collect();
    format!("{head}~{hex}")
}

fn text(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

fn attr(s: &str) -> String {
    text(s).replace('"', "&quot;").replace('\'', "&apos;")
}

// MARK: Banner text

/// Text for a toast (`BannerText` on the Mac): a toast has room for about two short lines, so it gets the gist (the
/// first sentence in plain words) instead of the whole reply. The full text stays one click away.
pub mod banner {
    use std::sync::OnceLock;

    /// Longest body line of an agent's toast.
    pub const LIMIT: usize = 90;
    /// Longest topic in a toast's subtitle, next to the folder.
    pub const SUBTITLE_LIMIT: usize = 48;

    /// The first sentence of `text` without Markdown, links shortened ("#1394", "github.com"), and cut at a word to
    /// at most `limit` characters.
    pub fn gist(text: &str, limit: usize) -> String {
        let first = text.lines().map(plain).find(|l| !l.is_empty()).unwrap_or_default();
        cut(&first_sentence(&first), limit)
    }

    /// `text` without Markdown marks and with its links shortened, on one line.
    pub fn plain(text: &str) -> String {
        static RULES: OnceLock<Vec<(regex::Regex, &'static str)>> = OnceLock::new();
        let rules = RULES.get_or_init(|| {
            [
                // [title](url) → title
                (r"\[([^\]]+)\]\([^)]+\)", "$1"),
                // A pull request or issue link → its number.
                (r"https?://[^\s)]+/(?:pull|issues|merge_requests)/(\d+)[^\s)]*", "#$1"),
                // Any other link → its host.
                (r"https?://(?:www\.)?([^/\s)]+)[^\s)]*", "$1"),
                (r"\*\*|__|`", ""),
                (r"(?m)^\s*(?:#{1,6}\s+|[-*+>]\s+|\d+[.)]\s+)", ""),
                (r"\s+", " "),
            ]
            .into_iter()
            .map(|(p, t)| (regex::Regex::new(p).expect("static pattern"), t))
            .collect()
        });
        let mut line = text.to_string();
        for (regex, template) in rules {
            line = regex.replace_all(&line, *template).into_owned();
        }
        line.trim().to_string()
    }

    /// Up to the end of the first sentence that says something (a few words at least): "Done. Tests pass." → "Done.".
    pub fn first_sentence(text: &str) -> String {
        const MINIMUM: usize = 12;
        let chars: Vec<char> = text.chars().collect();
        for (i, c) in chars.iter().enumerate() {
            if ".!?".contains(*c) && (i + 1 == chars.len() || chars[i + 1] == ' ') && i >= MINIMUM {
                return chars[..=i].iter().collect();
            }
        }
        text.to_string()
    }

    /// At most `limit` characters, cut at a word with an ellipsis (`TextKit.clip(wordBoundary:)`).
    pub fn cut(text: &str, limit: usize) -> String {
        if limit == 0 {
            return String::new();
        }
        if text.chars().count() <= limit {
            return text.to_string();
        }
        let head: String = text.chars().take(limit - 1).collect();
        let word = head.rfind(' ').map_or(head.as_str(), |i| &head[..i]);
        format!("{}…", word.trim_matches(|c: char| c.is_whitespace() || c.is_ascii_punctuation()))
    }

    /// An approval's context without the agent's name when the title already says it ("Claude Code · Fix it" under
    /// "Claude Code wants to …" → "Fix it").
    pub fn context(context: &str, title: &str) -> String {
        let parts: Vec<&str> = context.split(" · ").collect();
        match parts.first() {
            Some(agent) if parts.len() > 1 && !agent.is_empty() && title.contains(agent) => {
                cut(&parts[1..].join(" · "), SUBTITLE_LIMIT + 20)
            }
            _ => context.to_string(),
        }
    }

    /// "nook · Fix the login bug": where, and which session, in one short line.
    pub fn subtitle(project: &str, topic: &str) -> String {
        let topic = cut(topic, SUBTITLE_LIMIT);
        [project, topic.as_str()].iter().filter(|t| !t.is_empty()).copied().collect::<Vec<_>>().join(" · ")
    }
}

#[cfg(test)]
mod tests;
