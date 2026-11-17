//! Screen work on a model on this computer while an external brain answers the rest (Settings › Brain › Screen work).
//! The Mac's `AppModel.ask` routing with `ScreenBrain`, `answerFromBrief` and `answerTogether`:
//!
//! - a question about the screen (or a source kept on this computer) is answered by the screen brain itself, inside a
//!   run whose settings think on that model (`state::ROUTED`), so the screen never leaves this computer;
//! - with "It gives {brain} a short, filtered note", the screen brain reads the screen and writes a note
//!   (`private_brief`), and the chosen brain answers from that note with its own tools;
//! - a question that needs the screen and a lookup ("klopt wat hier staat met de mail van Henk?") goes to both: the
//!   chosen brain looks up its part without the screen, then the screen brain answers with that and the screen.

use std::time::Duration;

use nook_core::brain::conversation_window::as_text;
use nook_core::brain::intent::{ChatIntent, Kind};
use nook_core::brain::service::{self, BrainRequest};
use nook_core::brain::sources::SourceScope;
use nook_core::brain::{follow_ups, private_brief, screen_brain, ChatTurn, PromptImage, ToolKind};
use nook_core::i18n::{tr, trf};
use nook_core::settings::{BrainSelection, Settings};
use tauri::{AppHandle, Manager};

use super::chat::{self, Attachment};
use crate::state::{AppState, ROUTED};
use crate::tools::{self, ToolCtx};

/// Which brain answers a chat question.
#[derive(Debug, Clone)]
pub enum Route {
    /// The chosen brain, as always.
    Chosen,
    /// The screen brain answers. `together`: the chosen brain first looks up its part without the screen.
    Screen { worker: BrainSelection, together: bool },
    /// The screen brain writes a note; the chosen brain answers from it.
    Relay { worker: BrainSelection },
}

impl Route {
    /// The screen brain is on this computer: it may read the whole conversation.
    pub fn sees_everything(&self) -> bool {
        matches!(self, Self::Screen { .. })
    }
}

tokio::task_local! {
    /// The note and the mail addresses the screen brain read, for the chosen brain's answer. The addresses never
    /// leave this computer; `compose_mail` fills them in for a name.
    static BRIEF: (String, Vec<String>);
    /// What the chosen brain found for its part of a question for both brains.
    static OUTSIDE: String;
}

/// The note this answer is written from, for the brain's context.
pub fn brief_context() -> Option<String> {
    BRIEF.try_with(|(note, _)| private_brief::context(note)).ok()
}

/// The chosen brain's findings, for the screen brain's context.
pub fn outside_context() -> Option<String> {
    OUTSIDE.try_with(|found| screen_brain::outside_context(found)).ok()
}

/// The address the screen brain read for a name the chosen brain put in a draft (`private_brief::address_for`).
pub fn address_for(name: &str) -> Option<String> {
    BRIEF.try_with(|(_, addresses)| private_brief::address_for(name, addresses)).ok().flatten()
}

/// "Claude": the chosen brain, without what its title adds in brackets.
fn chosen_name(settings: &Settings) -> String {
    settings.provider.title().split(" (").next().unwrap_or("").to_string()
}

/// The route for a question, decided before it joins the conversation.
pub fn route(app: &AppHandle, settings: &Settings, nook_id: &str, text: &str, images: bool) -> Route {
    let Some(worker) = settings.screen_worker() else { return Route::Chosen };
    let state = app.state::<AppState>();
    let (picked, earlier, after_screen) = state.with_chat(|c| {
        let conversation = c.get(nook_id);
        let picked = conversation.and_then(|conv| conv.scope.clone()).unwrap_or_default();
        let messages = conversation.map(|conv| conv.messages.as_slice()).unwrap_or_default();
        let last = messages.iter().rev().find(|m| !m.from_user);
        let screen: std::collections::BTreeSet<String> = ["screen".to_string()].into();
        let after = last.is_some_and(|m| m.used(&screen) || !m.private_brief.is_empty());
        (picked, !messages.is_empty(), after)
    });
    // A question about another source kept on this computer ("wat is het nummer van Lisa?"): the model here may read it.
    let wanted = picked.merged(SourceScope::parse(text).as_ref());
    let private = settings.private_sources();
    let other_source = chat::withheld(settings, text, &wanted).iter().any(|s| s != "screen")
        || (private.contains("contacts") && ChatIntent::detect(text).kinds.contains(&Kind::Contacts));
    if !other_source && !screen_brain::handles(text, earlier, after_screen) {
        return Route::Chosen;
    }
    // The note reads the screen only: a question about another kept source is answered here.
    if settings.screen_brain_relays && !other_source && screen_brain::relays(text, images) {
        return Route::Relay { worker };
    }
    Route::Screen { worker, together: !images && screen_brain::needs_both(text) }
}

/// Answers the question on its route.
#[allow(clippy::too_many_arguments)]
pub async fn answer(
    app: AppHandle,
    nook_id: String,
    message_id: String,
    text: String,
    history: Vec<ChatTurn>,
    local_history: Vec<ChatTurn>,
    images: Vec<PromptImage>,
    attachment: Option<Attachment>,
    route: Route,
) {
    let settings = app.state::<AppState>().settings();
    let (nid, mid) = (nook_id.as_str(), message_id.as_str());
    match route {
        Route::Chosen => chat::answer_question(&app, nid, mid, &text, &history, images, attachment, false, None).await,
        Route::Screen { worker, together } => {
            let worker_name = screen_brain::name(&worker);
            let found = if together {
                chat::update(&app, nid, mid, |m| m.status = tr("Ik zoek op…", "Looking things up…").into());
                chosen_part(&app, nid, &text, &history).await
            } else {
                String::new()
            };
            let notice = if found.is_empty() {
                trf(
                    "Beantwoord door {name} op deze computer, omdat het over je scherm gaat.",
                    "Answered by {name} on this computer, because it is about your screen.",
                    &[("name", &worker_name)],
                )
            } else {
                trf(
                    "Je gekozen brein zocht op zonder je scherm te zien; {name} las je scherm en schreef dit antwoord op deze computer.",
                    "Your chosen brain looked things up without seeing your screen; {name} read your screen and wrote this answer on this computer.",
                    &[("name", &worker_name)],
                )
            };
            chat::update(&app, nid, mid, |m| m.notices.push(notice));
            let answer = chat::answer_question(&app, nid, mid, &text, &local_history, images, attachment, false, None);
            let answer = ROUTED.scope(screen_brain::routed(&settings, &worker), answer);
            if found.is_empty() {
                answer.await
            } else {
                OUTSIDE.scope(found, answer).await
            }
        }
        Route::Relay { worker } => {
            let worker_name = screen_brain::name(&worker);
            chat::update(&app, nid, mid, |m| m.status = tr("Leest op deze computer…", "Reading on this computer…").into());
            let routed = screen_brain::routed(&settings, &worker);
            let note = ROUTED.scope(routed.clone(), write_brief(&app, &routed, &text, &local_history)).await;
            match note {
                // Nothing to read or no note: nothing left this computer, and the model here answers as it would have.
                None => {
                    let notice = trf(
                        "Beantwoord door {name} op deze computer, omdat het over je scherm gaat.",
                        "Answered by {name} on this computer, because it is about your screen.",
                        &[("name", &worker_name)],
                    );
                    chat::update(&app, nid, mid, |m| m.notices.push(notice));
                    let answer = chat::answer_question(&app, nid, mid, &text, &local_history, images, attachment, false, None);
                    ROUTED.scope(routed, answer).await
                }
                Some((note, addresses)) => {
                    let notice = trf(
                        "{name} las mee op deze computer en gaf {chosen} een gefilterde notitie, zodat die kon antwoorden.",
                        "{name} read this on your computer and gave {chosen} a filtered note, so it could answer.",
                        &[("name", &worker_name), ("chosen", &chosen_name(&settings))],
                    );
                    let shown = note.clone();
                    chat::update(&app, nid, mid, |m| {
                        m.private_brief = shown;
                        m.notices.push(notice);
                        m.status = tr("Even nadenken…", "Thinking…").into();
                    });
                    let answer = chat::answer_question(&app, nid, mid, &text, &history, images, attachment, false, None);
                    BRIEF.scope((note, addresses), answer).await
                }
            }
        }
    }
}

/// Runs on the model on this computer, without tools: it reads the screen and writes a note. `None` when there is
/// nothing to read or the model gives no note.
async fn write_brief(app: &AppHandle, routed: &Settings, text: &str, history: &[ChatTurn]) -> Option<(String, Vec<String>)> {
    // Never a raw screen to anything but a model on this computer.
    if !routed.is_local_brain() || !(screen_brain::refers_to_screen(text) || screen_brain::follows_up(text)) {
        return None;
    }
    let profile = service::profile_for(routed, crate::brain::memory_gb());
    let task_app = app.clone();
    let small = profile.is_small;
    let snapshot = tauri::async_runtime::spawn_blocking(move || crate::services::screen::snapshot(&task_app, small)).await.ok()?.ok()?;
    let prompt = private_brief::prompt(text, &as_text(history, 6, 300), "", Some(&snapshot.text), profile.prompt_character_budget());
    let key = app.state::<AppState>().key_for(routed.provider);
    let raw = tokio::time::timeout(
        Duration::from_secs(60),
        nook_core::services::rewrite::complete(routed, key, private_brief::SYSTEM, &prompt, 600),
    )
    .await
    .ok()?
    .ok()?;
    let sealed = private_brief::sealed(&raw)?;
    Some((sealed, private_brief::addresses(&format!("{}\n{raw}", snapshot.text))))
}

/// The chosen brain's part of a question for both brains: read tools only, the sources kept on this computer out of its
/// reach (the tools keep them out by themselves for an external brain). Empty when it fails: the screen brain then
/// answers by itself.
async fn chosen_part(app: &AppHandle, nook_id: &str, text: &str, history: &[ChatTurn]) -> String {
    let settings = app.state::<AppState>().settings();
    let env = chat::brain_env(app, &settings);
    let ctx = ToolCtx::new(app, text).in_nook(nook_id);
    let tools: Vec<_> = tools::tools(&ctx).into_iter().filter(|t| t.kind == ToolKind::Read && t.name != "compose_mail").collect();
    let (overview, _) = tools::context_titled(&ctx).await;
    let request = BrainRequest {
        text: format!("{text}\n\n({})", screen_brain::OUTSIDE_INSTRUCTION),
        history: history.to_vec(),
        context: overview,
        screen: None,
        images: vec![],
        tools,
        own_request: false,
    };
    match tokio::time::timeout(Duration::from_secs(90), service::run(&settings, &env, request, None)).await {
        // Its citations point at lookups the answer on this computer does not have.
        Ok(Ok(plan)) => nook_core::brain::retrieval::citations::sanitize(&follow_ups::split(&plan.text).0, &Default::default()),
        _ => String::new(),
    }
}
