//! Nook itself for coding agents, the app half of `nook_core::workspace::bridge_nook` (the Mac's
//! `WorkspaceBridge+Nook` and `+Screen`): `nook_tools` and `nook_use` reach the brain's own tool registry
//! (`crate::tools`), `nook_chat_*` reach Nook Chat through the same question path as the chat window, and
//! `take_over_screen` lends the screen-reading tools to one session for a few minutes.
//!
//! Everything an agent sends is untrusted: arguments are cleaned against the tool's schema and checked by the action
//! gate, a read's result comes back without secrets and marked as data, and every side effect waits for the user's
//! yes in the bar's approval card, whatever rights the session has, and lands in the audit log.

use std::collections::BTreeSet;
use std::sync::Mutex;
use std::time::Duration;

use chrono::{Local, Utc};
use nook_core::brain::action_gate::{self, PlanExecutor, Step};
use nook_core::brain::sources::{self, SourceScope};
use nook_core::brain::{LoopTool, PlannedAction, ToolKind};
use nook_core::i18n::{tr, trf};
use nook_core::nooks::{Conversation, StepState};
use nook_core::workspace::bridge::{BridgeCaller, BridgeTool, Reason, ToolResult, Verdict};
use nook_core::workspace::bridge_nook::{self as rules, ScreenGrant, ToolInfo, SCREEN_TOOLS};
use serde_json::{Map, Value};
use tauri::{AppHandle, Manager};

use super::{audit, enabled, refusal, workspace, Context};
use crate::agents::lock;
use crate::state::AppState;
use crate::tools::{self, ToolCtx};

/// The session that may read the screen now, if any.
static SCREEN: Mutex<Option<ScreenGrant>> = Mutex::new(None);

fn screen_holder() -> Option<ScreenGrant> {
    lock(&SCREEN).clone().filter(|g| g.is_active(Utc::now()))
}

pub(super) async fn call(
    app: &AppHandle,
    tool: BridgeTool,
    a: &Map<String, Value>,
    caller: &BridgeCaller,
    context: &Context,
) -> Result<ToolResult, String> {
    match tool {
        BridgeTool::NookTools => nook_tools(app, a),
        BridgeTool::NookUse => nook_use(app, a, caller, context).await,
        BridgeTool::NookChatList => nook_chat_list(app, a),
        BridgeTool::NookChatRead => nook_chat_read(app, a),
        BridgeTool::NookChatSend => nook_chat_send(app, a, caller, context).await,
        BridgeTool::TakeOverScreen => take_over_screen(app, a, caller, context).await,
        _ => Err("Unknown Nook tool.".into()),
    }
}

/// What the user keeps on this device: never for an agent, whatever brain Nook Chat runs on.
fn kept(app: &AppHandle) -> BTreeSet<String> {
    app.state::<AppState>().settings().local_only_sources
}

/// The Nook tools an agent may use now: those of the sources that are on, without the ones kept on this device.
fn agent_tools(app: &AppHandle) -> Vec<(LoopTool, ToolInfo)> {
    let kept = kept(app);
    let ctx = ToolCtx::new(app, "");
    tools::all_tools(&ctx)
        .into_iter()
        .filter_map(|t| {
            let source = t.source.clone().or_else(|| sources::source_for_tool(&t.name));
            if !rules::for_agents(&t.name, source.as_deref(), &kept) {
                return None;
            }
            let info = ToolInfo {
                name: t.name.clone(),
                description: t.description.clone(),
                schema: t.schema.clone(),
                action: t.kind == ToolKind::Action,
                source: source.map(|s| sources::title(&s)).unwrap_or_else(|| "Nook".into()),
                screen: SCREEN_TOOLS.contains(&t.name.as_str()),
            };
            Some((t, info))
        })
        .collect()
}

fn nook_tools(app: &AppHandle, a: &Map<String, Value>) -> Result<ToolResult, String> {
    let infos: Vec<ToolInfo> = agent_tools(app).into_iter().map(|(_, i)| i).collect();
    let kept: Vec<String> = kept(app).iter().map(|s| sources::title(s)).collect();
    rules::catalog(&infos, super::arg(a, "tool"), super::arg(a, "query"), &kept).map(ToolResult::text)
}

/// Text from the user's apps as an agent gets it.
fn data(text: &str) -> ToolResult {
    ToolResult::text(nook_core::brain::text::wrap_untrusted(&rules::shielded(text)))
}

async fn nook_use(app: &AppHandle, a: &Map<String, Value>, caller: &BridgeCaller, context: &Context) -> Result<ToolResult, String> {
    let name = super::arg(a, "tool").to_string();
    let all = agent_tools(app);
    let Some((spec, _)) = all.iter().find(|(t, _)| t.name == name) else {
        return Err(format!("Nook has no tool \"{name}\" for agents right now. Call nook_tools for the list."));
    };
    let raw = a.get("arguments").filter(|v| v.is_object()).cloned().unwrap_or_else(|| Value::Object(Map::new()));
    let input = action_gate::normalized(&raw, &spec.schema);
    let action = spec.kind == ToolKind::Action;
    let verdict = if enabled(app) { rules::verdict(BridgeTool::NookUse, caller, action) } else { Verdict::Refuse(Reason::Disabled) };
    if let Verdict::Refuse(reason) = verdict {
        audit(app, BridgeTool::NookUse, caller, &name, &format!("geweigerd: {reason:?}"));
        return Err(refusal(reason).into());
    }

    if !action {
        if SCREEN_TOOLS.contains(&name.as_str()) && !screen_holder().is_some_and(|g| g.holds(&caller.key(), Utc::now())) {
            return Err("You do not have the screen. Ask for it first with take_over_screen; the user approves it in Nook.".into());
        }
        let problems = action_gate::problems(&name, &input, &spec.schema);
        if !problems.is_empty() {
            return Err(format!("{}\nArguments (JSON schema):\n{}", problems.join(" "), rules::pretty(&spec.schema)));
        }
        return match tokio::time::timeout(Duration::from_secs(120), (spec.run)(input)).await {
            Ok(Ok(output)) => {
                audit(app, BridgeTool::NookUse, caller, &name, "gelezen");
                Ok(data(&output))
            }
            Ok(Err(e)) => {
                audit(app, BridgeTool::NookUse, caller, &name, &format!("mislukt: {e}"));
                Err(e.0)
            }
            Err(_) => Err(format!("{name} took too long.")),
        };
    }

    // An action: checked as Nook Chat would check its own proposal, then shown in full on the card.
    let loop_tools: Vec<LoopTool> = all.iter().map(|(t, _)| t.clone()).collect();
    let planned = PlannedAction::new(&name, input.clone());
    let problems = crate::commands::chat::action_problems(&loop_tools, &planned, &SourceScope::default());
    if !problems.is_empty() {
        return Err(format!("{}\nArguments (JSON schema):\n{}", problems.join(" "), rules::pretty(&spec.schema)));
    }
    let summary = tools::summarize(&name, &input);
    let ws = workspace(app).ok_or("Nook is not ready.")?;
    let allowed = ws
        .bridge
        .ask(
            app,
            caller,
            BridgeTool::NookUse,
            trf("{agent} wil iets doen met Nook", "{agent} wants to do something with Nook", &[("agent", &caller.agent)]),
            rules::action_detail(&summary, &input),
            tr("Het gebeurt in je eigen apps en koppelingen, precies zoals hier staat.", "It happens in your own apps and connections, exactly as shown here.").into(),
            &context.connection,
        )
        .await;
    if !allowed {
        audit(app, BridgeTool::NookUse, caller, &name, "niet toegestaan");
        return Err(refusal(Reason::Outward).into());
    }
    let executor = Executor { app: app.clone(), ctx: ToolCtx::new(app, ""), all: loop_tools, caller: caller.agent.clone() };
    let step = Step { tool: name.clone(), input };
    let states = action_gate::run_plan(&executor, std::slice::from_ref(&step), &[], &[true], &[]).await;
    match states.into_iter().next() {
        Some(StepState::Done(r)) | Some(StepState::Verified(r)) => {
            audit(app, BridgeTool::NookUse, caller, &name, "uitgevoerd");
            Ok(data(&r))
        }
        Some(StepState::Duplicate(when)) => Err(format!("This exact action already ran ({when}); Nook does not repeat it.")),
        Some(StepState::Failed(e)) => {
            audit(app, BridgeTool::NookUse, caller, &name, &format!("mislukt: {e}"));
            Err(e)
        }
        _ => Err("The action did not run.".into()),
    }
}

/// Runs one approved Nook action the way a plan in Nook Chat does: checked again right before, never twice.
struct Executor {
    app: AppHandle,
    ctx: ToolCtx,
    all: Vec<LoopTool>,
    caller: String,
}

#[async_trait::async_trait]
impl PlanExecutor for Executor {
    fn check(&self, step: &Step) -> Vec<String> {
        crate::commands::chat::action_problems(&self.all, &PlannedAction::new(&step.tool, step.input.clone()), &SourceScope::default())
    }

    async fn execute(&self, step: &Step) -> Result<String, String> {
        let state = self.app.state::<AppState>();
        let args = format!("{} · {}", self.caller, step.input);
        let result = tools::execute(&self.ctx, &step.tool, &step.input).await;
        match &result {
            Ok(r) => state.store.audit(&step.tool, &args, r),
            Err(e) => state.store.audit(&step.tool, &args, &format!("FOUT: {e}")),
        }
        result
    }

    fn executed_before(&self, key: &str) -> Option<String> {
        let when = self.app.state::<AppState>().store.executed_action(key, action_gate::DUPLICATE_WINDOW_SECS)?;
        Some(nook_core::brain::dates::short(&when.with_timezone(&Local)))
    }

    fn record_executed(&self, key: &str, step: &Step, result: &str) {
        self.app.state::<AppState>().store.record_executed(key, &step.tool, result);
    }

    async fn verify(&self, step: &Step, result: &str) -> Option<bool> {
        tools::verify(&self.ctx, &step.tool, &step.input, result).await
    }
}

// MARK: Nook Chat

fn limit(a: &Map<String, Value>, default: u64, max: u64) -> usize {
    a.get("limit").and_then(Value::as_u64).unwrap_or(default).clamp(1, max) as usize
}

fn nook_chat_list(app: &AppHandle, a: &Map<String, Value>) -> Result<ToolResult, String> {
    let kept = kept(app);
    let text = app.state::<AppState>().with_chat(|c| rules::chat_list(&c.conversations, limit(a, 15, 40), &kept));
    Ok(data(&text))
}

fn nook_chat_read(app: &AppHandle, a: &Map<String, Value>) -> Result<ToolResult, String> {
    let kept = kept(app);
    let id = super::arg(a, "conversation_id").to_string();
    let conversation = app.state::<AppState>().with_chat(|c| c.get(&id).cloned()).ok_or("No such conversation. Use an id from nook_chat_list.")?;
    Ok(data(&rules::chat_read(&conversation, limit(a, 20, 60), &kept, &|tool, input| tools::summarize(tool, input))))
}

async fn nook_chat_send(app: &AppHandle, a: &Map<String, Value>, caller: &BridgeCaller, context: &Context) -> Result<ToolResult, String> {
    let message = super::arg(a, "message").to_string();
    if message.is_empty() {
        return Err("Give the message for Nook.".into());
    }
    if message.chars().count() > 8_000 {
        return Err("The message is too long for Nook Chat (at most 8000 characters).".into());
    }
    let state = app.state::<AppState>();
    let settings = state.settings();
    if !nook_core::brain::service::brain_ready(&settings, state.key_for(settings.provider).is_some_and(|k| !k.is_empty())) {
        return Err("Nook Chat has no brain set up yet; the user chooses one in Settings.".into());
    }
    let wanted = super::arg(a, "conversation_id").to_string();
    let target = if wanted.is_empty() {
        None
    } else {
        let busy = state
            .with_chat(|c| c.get(&wanted).map(|conv| conv.busy))
            .ok_or("No such conversation. Use an id from nook_chat_list, or leave conversation_id out to start a new one.")?;
        // Asking again would stop the answer Nook is writing.
        if busy {
            return Err("Nook is still answering in this conversation. Wait and try again.".into());
        }
        Some(wanted)
    };
    let verdict = if enabled(app) { rules::verdict(BridgeTool::NookChatSend, caller, true) } else { Verdict::Refuse(Reason::Disabled) };
    if let Verdict::Refuse(reason) = verdict {
        return Err(refusal(reason).into());
    }
    let title = target.as_ref().and_then(|id| state.with_chat(|c| c.get(id).map(|conv| conv.title.clone())));
    let ws = workspace(app).ok_or("Nook is not ready.")?;
    let allowed = ws
        .bridge
        .ask(
            app,
            caller,
            BridgeTool::NookChatSend,
            trf("{agent} wil iets vragen in Nook Chat", "{agent} wants to ask something in Nook Chat", &[("agent", &caller.agent)]),
            title.map(|t| format!("*{t}*\n\n{message}")).unwrap_or_else(|| message.clone()),
            tr("Nook antwoordt met je eigen bronnen; wat Nook voorstelt te doen, wacht daarna nog op jou.", "Nook answers with your own sources; anything Nook proposes to do still waits for you.").into(),
            &context.connection,
        )
        .await;
    if !allowed {
        audit(app, BridgeTool::NookChatSend, caller, &message, "niet toegestaan");
        return Err(refusal(Reason::NeedsReview).into());
    }
    // A new conversation in the background: the user's open chat stays where it is.
    let id = target.unwrap_or_else(|| {
        state.with_chat(|c| {
            let conversation = Conversation::new();
            let id = conversation.id.clone();
            c.conversations.insert(0, conversation);
            id
        })
    });
    crate::commands::chat::ask(app, &id, &rules::chat_question(caller, &message), vec![], None)?;
    audit(app, BridgeTool::NookChatSend, caller, &message, "verstuurd");

    if !a.get("wait").and_then(Value::as_bool).unwrap_or(true) {
        return Ok(ToolResult::text(format!("Sent to Nook Chat (conversation {id}). Read the answer later with nook_chat_read.")));
    }
    let timeout = a.get("timeout_seconds").and_then(Value::as_u64).unwrap_or(90).clamp(1, 300);
    let deadline = tokio::time::Instant::now() + Duration::from_secs(timeout);
    while state.with_chat(|c| c.get(&id).is_some_and(|conv| conv.busy)) && tokio::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    let kept = kept(app);
    let conversation = state.with_chat(|c| c.get(&id).cloned()).ok_or("The conversation is gone.")?;
    let mut lines = vec![format!("Conversation: {id}")];
    if conversation.busy {
        lines.push("Nook is still answering; read it later with nook_chat_read.".into());
    } else if let Some(reply) = conversation.messages.last().filter(|m| !m.from_user) {
        lines.push(rules::render(reply, &kept, &|tool, input| tools::summarize(tool, input)));
    }
    Ok(data(&lines.join("\n\n")))
}

// MARK: The screen

async fn take_over_screen(app: &AppHandle, a: &Map<String, Value>, caller: &BridgeCaller, context: &Context) -> Result<ToolResult, String> {
    let key = caller.key();
    if a.get("stop").and_then(Value::as_bool).unwrap_or(false) {
        let mut grant = lock(&SCREEN);
        if grant.as_ref().is_none_or(|g| g.holder != key) {
            return Ok(ToolResult::text("You do not have the screen."));
        }
        *grant = None;
        drop(grant);
        audit(app, BridgeTool::TakeOverScreen, caller, "stop", "teruggegeven");
        return Ok(ToolResult::text("The screen is the user's again."));
    }
    let verdict = if enabled(app) { rules::verdict(BridgeTool::TakeOverScreen, caller, true) } else { Verdict::Refuse(Reason::Disabled) };
    if let Verdict::Refuse(reason) = verdict {
        return Err(refusal(reason).into());
    }
    if kept(app).contains(sources::SCREEN) {
        return Err("The user keeps the screen on this device (Settings › Privacy), so agents cannot see it.".into());
    }
    if !app.try_state::<crate::services::Services>().is_some_and(|s| s.platform.screen.available()) {
        return Err("Nook cannot read the screen on this device.".into());
    }
    if let Some(holder) = screen_holder() {
        if holder.holder != key {
            return Err(format!("{} is using the screen now. Try again later.", holder.agent));
        }
        return Ok(ToolResult::text(format!("You have the screen until {}.", clock(&holder))));
    }
    let reason = super::arg(a, "reason").to_string();
    if reason.is_empty() {
        return Err("Give the reason: what you will look at on the screen and why.".into());
    }
    let minutes = ScreenGrant::minutes(a.get("minutes").and_then(Value::as_i64));
    let ws = workspace(app).ok_or("Nook is not ready.")?;
    let allowed = ws
        .bridge
        .ask(
            app,
            caller,
            BridgeTool::TakeOverScreen,
            trf("{agent} wil je scherm lezen", "{agent} wants to read your screen", &[("agent", &caller.agent)]),
            reason.clone(),
            trf(
                "{minutes} minuten lang, alleen lezen: Nook klikt en typt niet voor agents.",
                "For {minutes} minutes, read-only: Nook does not click or type for agents.",
                &[("minutes", &minutes)],
            ),
            &context.connection,
        )
        .await;
    if !allowed {
        audit(app, BridgeTool::TakeOverScreen, caller, &reason, "niet toegestaan");
        return Err(refusal(Reason::NeedsReview).into());
    }
    let grant = {
        let mut slot = lock(&SCREEN);
        // Someone else may have taken it while the card waited.
        if let Some(other) = slot.as_ref().filter(|g| g.is_active(Utc::now()) && g.holder != key) {
            return Err(format!("{} is using the screen now. Try again later.", other.agent));
        }
        let grant = ScreenGrant::new(caller, minutes, Utc::now());
        *slot = Some(grant.clone());
        grant
    };
    audit(app, BridgeTool::TakeOverScreen, caller, &reason, &format!("{minutes} min"));
    Ok(ToolResult::text(format!(
        "You have the screen until {} ({minutes} minutes), read-only.\nUse nook_use with read_screen (all windows), read_app (one app), list_running_apps and get_active_app. On this platform Nook cannot click or type for you. Call take_over_screen with stop: true when you are done.",
        clock(&grant)
    )))
}

fn clock(grant: &ScreenGrant) -> String {
    grant.until.with_timezone(&Local).format("%H:%M").to_string()
}
