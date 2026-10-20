//! Een vraag aan Nook: snelle opdrachten zonder brein, en anders een antwoord dat binnenkomt terwijl het geschreven wordt,
//! met per bron wat er opgezocht is, genummerde bronnen, grafieken, mailconcepten en een plan dat pas na Uitvoeren iets doet.

use std::collections::{BTreeSet, HashSet};
use std::sync::Arc;
use std::time::{Duration, Instant};

use nook_core::brain::local_intent::LocalIntent;
use nook_core::brain::memory::{reflection, request as memory_request, Change, MemoryBook, MemoryKind, Origin};
use nook_core::brain::prepare::{self, ContextParts, ResearchInput};
use nook_core::brain::quality::{evidence, grounding};
use nook_core::brain::retrieval::{citations, ledgered, Outcome, RetrievalLedger};
use nook_core::brain::service::{self, BrainEnv, BrainRequest};
use nook_core::brain::sources::{self, SourceScope};
use nook_core::brain::suggestions::{self, Recovery};
use nook_core::brain::{
    action_gate, chart, follow_ups, intent::ChatIntent, research, undo, ChatTurn, LoopTool, PlannedAction, PromptImage,
};
use nook_core::nooks::{ChatMessage, PlanState, StepState};
use nook_core::settings::Settings;
use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter, Manager};

use crate::brain::BrainState;
use crate::state::AppState;
use crate::tools::{self, Reply, ToolCtx};

/// Een bijlage bij een vraag: de naam en de tekst die Nook eruit las.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Attachment {
    pub name: String,
    pub text: String,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct StreamEvent<'a> {
    nook_id: &'a str,
    message_id: &'a str,
    text: String,
}

pub fn updated(app: &AppHandle, id: &str) {
    let _ = app.emit("nook-updated", id);
}

/// Past een bericht aan en meldt het aan de interface.
pub fn update(app: &AppHandle, nook_id: &str, message_id: &str, change: impl FnOnce(&mut ChatMessage)) {
    let state = app.state::<AppState>();
    let changed = state.with_chat(|c| {
        let Some(message) = c.get_mut(nook_id).and_then(|conv| conv.messages.iter_mut().find(|m| m.id == message_id)) else { return false };
        change(message);
        true
    });
    if changed {
        updated(app, nook_id);
    }
}

/// Zet grafieken en mailconcepten van tools bij het antwoord dat nu geschreven wordt, of anders in de actieve Nook.
pub fn attach(app: &AppHandle, reply: Option<&Reply>, change: impl FnOnce(&mut ChatMessage)) {
    let state = app.state::<AppState>();
    let target = state.with_chat(|c| {
        if let Some(reply) = reply {
            if let Some(m) = c.get_mut(&reply.nook_id).and_then(|conv| conv.messages.iter_mut().find(|m| m.id == reply.message_id)) {
                change(m);
                return Some(reply.nook_id.clone());
            }
        }
        let id = c.active_or_new();
        let mut message = ChatMessage::nook("");
        change(&mut message);
        c.push(&id, message);
        Some(id)
    });
    if let Some(id) = target {
        state.save_chat();
        updated(app, &id);
    }
}

fn env(app: &AppHandle, settings: &Settings) -> BrainEnv {
    BrainEnv {
        key: app.state::<AppState>().key_for(settings.provider),
        memory_gb: crate::brain::memory_gb(),
        country: crate::brain::country(),
        timezone: crate::brain::timezone(),
    }
}

/// Een snelle opdracht of een fout: vraag en antwoord meteen in de Nook, zonder brein.
fn quick_reply(app: &AppHandle, nook_id: &str, question: &str, answer: ChatMessage) {
    let state = app.state::<AppState>();
    state.with_chat(|c| {
        c.push(nook_id, ChatMessage::user(question));
        c.push(nook_id, answer);
    });
    state.save_chat();
    updated(app, nook_id);
}

fn plan_message(text: &str, actions: Vec<PlannedAction>, problems: Vec<Vec<String>>) -> ChatMessage {
    let mut message = ChatMessage::nook(text);
    message.action_states = vec![StepState::Pending; actions.len()];
    message.action_included = vec![true; actions.len()];
    message.action_problems = problems;
    message.plan_state = Some(PlanState::Pending);
    message.actions = actions;
    message
}

/// Een vraag in deze Nook. Geeft meteen het id van het antwoord terug (of niets bij een snelle opdracht).
pub fn ask(
    app: &AppHandle,
    nook_id: &str,
    raw: &str,
    images: Vec<PromptImage>,
    attachment: Option<Attachment>,
) -> Result<Option<String>, String> {
    let mut text = raw.trim().to_string();
    if text.is_empty() && images.is_empty() && attachment.is_none() {
        return Err("Lege vraag".into());
    }
    if text.is_empty() {
        text = if attachment.is_some() { "Wat staat er in dit bestand?".into() } else { "Wat zie je op deze afbeelding?".into() };
    }
    let state = app.state::<AppState>();
    let settings = state.settings();

    // "Maak ongedaan": de laatste acties, omgekeerd, als plan om goed te keuren.
    if undo::is_request(&text) {
        propose_undo(app, nook_id, &text);
        return Ok(None);
    }
    // Korte vaste opdrachten doet Nook zelf, meteen.
    if images.is_empty() && attachment.is_none() {
        if let Some(intent) = LocalIntent::parse(&text, &|name| tools::find_app(app, name)) {
            if let Some(answer) = quick(app, &intent) {
                quick_reply(app, nook_id, &text, answer);
                return Ok(None);
            }
        }
    }
    if !service::brain_ready(&settings, state.key_for(settings.provider).is_some_and(|k| !k.is_empty())) {
        let mut answer = ChatMessage::nook(&not_ready(&settings));
        answer.is_error = true;
        answer.recovery = serde_json::to_value(Recovery::for_error(&answer.text, &settings.selection())).ok();
        quick_reply(app, nook_id, &text, answer);
        return Ok(None);
    }

    let mut answer = ChatMessage::nook("");
    answer.streaming = true;
    answer.status = "Even nadenken…".into();
    if !images.is_empty() && !settings.provider.sees_images(&settings.active_model()) {
        answer.notices.push("Dit brein kan geen afbeeldingen zien. Kies Claude, OpenAI, Gemini of een lokaal model dat plaatjes ziet (Qwen 3.5/3.6, Gemma 3/4) in Instellingen › Brein.".into());
    }
    let message_id = answer.id.clone();
    let hidden = settings.private_sources();
    let history = state.with_chat(|c| {
        let history = c.get(nook_id).map(|conv| conv.history_hiding(12, &hidden)).unwrap_or_default();
        let mut question = ChatMessage::user(&text);
        question.images = images.iter().map(|i| format!("data:{};base64,{}", i.media_type, i.base64)).collect();
        question.attachment = attachment.as_ref().map(|a| a.name.clone());
        c.push(nook_id, question);
        c.push(nook_id, answer);
        if let Some(conv) = c.get_mut(nook_id) {
            conv.busy = true;
        }
        history
    });
    updated(app, nook_id);

    let task_app = app.clone();
    let (nid, mid) = (nook_id.to_string(), message_id.clone());
    let handle = tauri::async_runtime::spawn(async move {
        answer_question(&task_app, &nid, &mid, &text, &history, images, attachment, false, None).await;
    });
    state.running.lock().unwrap_or_else(|e| e.into_inner()).insert(nook_id.to_string(), handle.inner().abort_handle());
    Ok(Some(message_id))
}

fn not_ready(settings: &Settings) -> String {
    use nook_core::provider::AIProvider;
    match settings.provider {
        AIProvider::Ollama => "Kies eerst een model voor Ollama bij Instellingen › Brein.".into(),
        AIProvider::ClaudeCode => "Claude Code staat niet op deze computer. Installeer het en log in met `claude`, of kies een ander brein bij Instellingen › Brein.".into(),
        AIProvider::Claude => "Er is nog geen Anthropic API-sleutel. Plak hem bij Instellingen › Brein.".into(),
        other => format!("Er is nog geen sleutel of model voor {}. Kies ze bij Instellingen › Brein.", other.title()),
    }
}

/// Een snelle opdracht die meteen een antwoord heeft, of niets (dan gaat de vraag naar het brein).
fn quick(app: &AppHandle, intent: &LocalIntent) -> Option<ChatMessage> {
    let media = app.try_state::<Arc<dyn nook_core::platform::MediaControl>>();
    let cannot = |what: &str| ChatMessage::nook(&format!("{what} kan nog niet op dit platform."));
    Some(match intent {
        LocalIntent::Time => ChatMessage::nook(&format!("Het is {}.", chrono::Local::now().format("%H:%M"))),
        LocalIntent::Media(action) => {
            let Some(media) = media else { return Some(cannot("Muziek bedienen")) };
            let command = match action.as_str() {
                "next" => nook_core::platform::MediaCommand::Next,
                "previous" => nook_core::platform::MediaCommand::Previous,
                _ => nook_core::platform::MediaCommand::PlayPause,
            };
            match media.send(command) {
                Ok(()) => ChatMessage::nook(match action.as_str() {
                    "next" => "Volgend nummer.",
                    "previous" => "Vorig nummer.",
                    _ => "Gedaan.",
                }),
                Err(e) => ChatMessage { is_error: true, ..ChatMessage::nook(&e) },
            }
        }
        LocalIntent::Volume(level) => {
            if media.is_none() {
                return Some(cannot("Het volume regelen"));
            }
            plan_message("", vec![PlannedAction::new("set_volume", serde_json::json!({"level": level}))], vec![vec![]])
        }
        LocalIntent::VolumeStep(step) => {
            if media.is_none() {
                return Some(cannot("Het volume regelen"));
            }
            ChatMessage::nook(if *step > 0 {
                "Zeg erbij hoe hard, bijvoorbeeld \"volume 60\"."
            } else {
                "Zeg erbij hoe zacht, bijvoorbeeld \"volume 20\"."
            })
        }
        LocalIntent::OpenApp(name) => {
            plan_message("", vec![PlannedAction::new("open_app", serde_json::json!({"name": name}))], vec![vec![]])
        }
        LocalIntent::ShowTab(tab) => {
            let route = match tab.as_str() {
                "agents" => "agents",
                "connect" => "settings",
                _ => "chat",
            };
            #[cfg(desktop)]
            crate::platform::desktop::show_main(app, route);
            #[cfg(not(desktop))]
            let _ = app.emit("navigate", route);
            ChatMessage::nook(match route {
                "agents" => "Hier zijn je agents.",
                "settings" => "Je koppelingen staan bij Instellingen.",
                _ => "Hier is de chat.",
            })
        }
        // Het weekoverzicht maakt het brein, met je agenda en wat er gedaan is.
        LocalIntent::WeekRecap => return None,
    })
}

/// De laatste reeks acties die Nook uitvoerde, omgedraaid als plan.
fn propose_undo(app: &AppHandle, nook_id: &str, asked: &str) {
    let brain = app.state::<BrainState>();
    let done: Vec<(crate::brain::Done, chrono::DateTime<chrono::Utc>)> =
        brain.done.lock().unwrap_or_else(|e| e.into_inner()).iter().map(|d| (d.clone(), d.date)).collect();
    let batch = undo::batch(&done, chrono::Utc::now());
    if batch.is_empty() {
        quick_reply(app, nook_id, asked, ChatMessage::nook("Ik heb het afgelopen half uur niets gedaan dat ik ongedaan kan maken."));
        return;
    }
    let steps: Vec<PlannedAction> =
        batch.iter().filter_map(|d| undo::step(&d.tool, &d.input, &d.result)).map(|s| PlannedAction::new(&s.tool, s.input)).collect();
    if steps.is_empty() {
        quick_reply(
            app,
            nook_id,
            asked,
            ChatMessage::nook("Wat ik net deed (een bericht of mail versturen, iets aanpassen) kan ik niet ongedaan maken."),
        );
        return;
    }
    let text = if steps.len() < batch.len() {
        "Dit kan ik terugdraaien; de rest (een verstuurd bericht of een aanpassing) niet:"
    } else {
        "Dit draai ik terug. Klik op Uitvoeren:"
    };
    let ctx = ToolCtx::new(app, asked).in_nook(nook_id);
    let all = tools::all_tools(&ctx);
    let problems = steps.iter().map(|a| action_problems(&all, a, &SourceScope::default())).collect();
    quick_reply(app, nook_id, asked, plan_message(text, steps, problems));
}

/// Problemen met een voorgestelde actie: de tool is er niet, de bron staat uit, of de invoer klopt niet.
pub fn action_problems(all: &[LoopTool], action: &PlannedAction, scope: &SourceScope) -> Vec<String> {
    let Some(spec) = all.iter().find(|t| t.name == action.tool && tools::is_action(t)) else {
        return vec![format!("{} is nu niet beschikbaar (koppeling uit of niet ingesteld).", action.tool)];
    };
    if !scope.allows_tool(&action.tool) {
        let source = spec.source.clone().or_else(|| sources::source_for_tool(&action.tool)).unwrap_or_default();
        return vec![format!("{} staat uit voor deze Nook (bronkiezer).", sources::title(&source))];
    }
    action_gate::problems(&action.tool, &action.input, &spec.schema)
}

fn memory_limits(settings: &Settings) -> (usize, usize) {
    let profile = service::profile_for(settings, crate::brain::memory_gb());
    match (profile.is_small, profile.roomy()) {
        (false, _) => (14, 2_200),
        (true, true) => (8, 1_100),
        (true, false) => (5, 650),
    }
}

/// Wat het antwoord niet kon gebruiken omdat het alleen op dit apparaat mag, terwijl de vraag erom vroeg.
fn withheld(settings: &Settings, text: &str, scope: &SourceScope) -> BTreeSet<String> {
    let hidden = settings.private_sources();
    if hidden.is_empty() {
        return BTreeSet::new();
    }
    let mut named: BTreeSet<String> = sources::mentions(text).into_iter().flat_map(|(_, ids)| ids).collect();
    named.extend(scope.focus.iter().cloned());
    if scope.mode == sources::ScopeMode::Only {
        named.extend(scope.included.iter().cloned());
    }
    hidden.intersection(&named).cloned().collect()
}

#[allow(clippy::too_many_arguments)]
pub async fn answer_question(
    app: &AppHandle,
    nook_id: &str,
    message_id: &str,
    text: &str,
    history: &[ChatTurn],
    images: Vec<PromptImage>,
    attachment: Option<Attachment>,
    retry: bool,
    correction: Option<String>,
) {
    let state = app.state::<AppState>();
    let brain = app.state::<BrainState>();
    let settings = state.settings();
    let env = env(app, &settings);
    let profile = service::profile_for(&settings, env.memory_gb);
    let wants_chart = chart::wants_chart(text);

    // De keuze in de bronkiezer, samen met wat de vraag zegt ("alleen mijn agenda en mail"); een extern brein krijgt de
    // bronnen die alleen op dit apparaat mogen nooit, ook niet als de vraag erom vraagt.
    let picked = state.with_chat(|c| c.get(nook_id).and_then(|conv| conv.scope.clone())).unwrap_or_default();
    let requested = SourceScope::parse(text);
    let wanted = picked.merged(requested.as_ref());
    let held_back = withheld(&settings, text, &wanted);
    let ctx = ToolCtx::new(app, text).in_nook(nook_id).with_scope(wanted).for_reply(nook_id, message_id);
    let scope = ctx.scope.clone();

    // Wat er opgezocht wordt, staat live boven het antwoord.
    let ledger = {
        let (app, nid, mid) = (app.clone(), nook_id.to_string(), message_id.to_string());
        Arc::new(RetrievalLedger::with_on_change(Box::new(move |steps| {
            update(&app, &nid, &mid, |m| {
                if let Some(running) = steps.iter().rev().find(|s| s.outcome == Outcome::Running) {
                    if m.text.is_empty() {
                        m.status = format!("Ik kijk in {}…", running.source_title);
                    }
                }
                m.retrieval = steps;
            });
        })))
    };
    let tools: Vec<LoopTool> = tools::tools(&ctx).into_iter().map(|t| ledgered(t, ledger.clone(), Duration::from_secs(25))).collect();
    let active = tools::active(&tools);

    brain.urls.note(text);
    if let Some(a) = &attachment {
        brain.urls.note(&a.text);
    }

    // Wat Nook onthoudt en wat bij deze vraag hoort; een vervolgvraag haalt ook terug met de vraag ervoor.
    let mut recalled = vec![];
    if settings.use_memory && scope.allows(sources::MEMORY) {
        let recall_text = match history.iter().rev().find(|t| t.from_user) {
            Some(previous) => format!("{text}\n{}", previous.text),
            None => text.to_string(),
        };
        let (limit, characters) = memory_limits(&settings);
        let names: HashSet<String> = tools.iter().map(|t| t.name.clone()).collect();
        recalled = brain.memory.recall(&recall_text, &names, limit, characters, settings.is_local_brain());
    }
    let (overview, mut context_titles) = tools::context_titled(&ctx).await;
    if !recalled.is_empty() {
        context_titles.push(sources::title(sources::MEMORY));
    }
    {
        let titles = context_titles.clone();
        let label = if scope.is_restricted() { scope.label() } else { String::new() };
        let sources = attachment.as_ref().map(|a| vec![a.name.clone()]).unwrap_or_default();
        let status = if retry {
            if wants_chart {
                "Ik teken de grafiek…"
            } else {
                "Ik zoek verder…"
            }
        } else {
            "Even nadenken…"
        };
        update(app, nook_id, message_id, |m| {
            m.context_sources = titles;
            m.scope_label = label;
            m.sources = sources;
            if m.text.is_empty() {
                m.status = status.into();
            }
        });
    }

    // Nook zoekt zelf, voor elk model: in elke relevante bron met de woorden die de vraag dragen, en leest de beste
    // treffers volledig. Het brein leest de vraag eerst zelf, als dat lukt.
    let intent = ChatIntent::detect(text);
    let mut findings = prepare::Findings::default();
    let mut goal = String::new();
    let mut blocked = vec![];
    let mut evidence_text = String::new();
    if !intent.is_small_talk {
        let available = prepare::available(&tools);
        let unreachable = tools::unreachable(&ctx);
        let plan = if prepare::should_plan(text, &intent) {
            let planner = prepare::planner_sources(&available, &scope, &active, &unreachable);
            service::plan(&settings, &env, text, history, &planner).await
        } else {
            None
        };
        goal = plan.as_ref().map(|p| p.goal.clone()).unwrap_or_default();
        let mut named: HashSet<String> = sources::mentions(text).into_iter().flat_map(|(_, ids)| ids).collect();
        if let Some(plan) = &plan {
            named.extend(plan.sources.iter().cloned());
        }
        for (id, reason) in unreachable.iter().filter(|(id, _)| named.contains(id) && scope.allows(id)) {
            blocked.push(format!("{} ({reason})", sources::title(id)));
            ledger.note_unavailable(id, id, reason);
        }
        let memory = brain.memory.clone();
        let use_memory = settings.use_memory;
        let learned =
            move |terms: &[String], allowed: &HashSet<String>| if use_memory { memory.suggest_sources(terms, allowed) } else { vec![] };
        findings = prepare::research(&ResearchInput {
            text,
            history,
            scope: &scope,
            tools: &tools,
            active: &active,
            plan: plan.as_ref(),
            profile,
            learned: &learned,
        })
        .await;
        // Een klein brein leest en antwoordt slecht in één keer: eerst een smalle stap die woord voor woord kopieert wat ertoe doet.
        if settings.evidence_first && profile.is_small && !findings.opened.is_empty() {
            update(app, nook_id, message_id, |m| m.status = "Ik lees wat ik vond…".into());
            evidence_text = evidence::section(&service::extract_evidence(&settings, &env, text, &goal, &findings.opened).await);
        }
    }
    let searched = prepare::searched_line(&ledger.steps(), &findings.terms);
    let memories = MemoryBook::section(&recalled);
    let context = prepare::build_context(&ContextParts {
        overview: &overview,
        memories: &memories,
        goal: &goal,
        blocked: &blocked,
        searched: &searched,
        evidence: &evidence_text,
        findings: &findings,
    });

    let mut request = text.to_string();
    if let Some(correction) = &correction {
        request += &format!("\n\n({correction} {})", settings.language_instruction(text));
    } else if retry {
        request += &if wants_chart {
            "\n\n(Render the chart now using the show_chart tool with real numbers from context, tools, or web. Do not write code, JSON, or a table as a substitute.)".to_string()
        } else {
            format!("\n\n(Your previous answer was empty, or contained code/JSON or was in the wrong language. Answer the question itself, in plain sentences, {} Use the context and what was looked up; if something is missing, fetch it with the matching tool. If it really is not possible, briefly say where you looked and what was missing.)", settings.language_instruction(text))
        };
    }

    // Een bijlage gaat voor; anders het scherm als de vraag erom vraagt (of als dat altijd mag).
    let screen = match attachment.as_ref() {
        Some(a) => {
            let limit = if profile.is_small { 12_000 } else { 40_000 };
            Some((format!("Bestand — {}", a.name), a.text.chars().take(limit).collect::<String>()))
        }
        None => crate::services::screen::for_question(app, nook_id, message_id, text).await,
    };
    let last = std::sync::Mutex::new((Instant::now() - Duration::from_secs(1), String::new()));
    let emit = |partial: String| {
        let mut visible = follow_ups::streaming_body(&partial);
        if wants_chart {
            visible = chart::hiding_chart_code(&visible);
        }
        let cleaned = suggestions::clean_reply(&visible);
        let mut guard = last.lock().unwrap_or_else(|e| e.into_inner());
        if cleaned == guard.1 || guard.0.elapsed() < Duration::from_millis(40) {
            return;
        }
        *guard = (Instant::now(), cleaned.clone());
        let _ = app.emit("nook-stream", StreamEvent { nook_id, message_id, text: cleaned });
    };
    let brain_request = BrainRequest {
        text: request,
        history: history.to_vec(),
        context: context.clone(),
        screen: screen.clone(),
        images: images.clone(),
        tools: tools.clone(),
        own_request: false,
    };
    let result = service::run(&settings, &env, brain_request, Some(&emit)).await;

    let plan = match result {
        Ok(plan) => plan,
        Err(e) => {
            finish_error(app, nook_id, message_id, &e.0, &settings);
            return;
        }
    };
    let (mut body, offers) = follow_ups::split(&plan.text);

    // Een klein brein verzint soms een getal, tijd of adres. Nook vergelijkt die met alles wat het kreeg, en laat het
    // antwoord opnieuw schrijven als er een nergens staat.
    if settings.check_answers
        && profile.is_small
        && !retry
        && !wants_chart
        && plan.actions.is_empty()
        && body.chars().count() >= 20
        && !grounding::may_compute(text)
    {
        let given = [
            context.as_str(),
            text,
            screen.as_ref().map(|s| s.1.as_str()).unwrap_or(""),
            &ledger.retrieved_text(),
            &history.iter().map(|h| h.text.clone()).collect::<Vec<_>>().join("\n"),
        ]
        .join("\n");
        let loose = grounding::ungrounded(&body, &given);
        if !loose.is_empty() {
            update(app, nook_id, message_id, |m| {
                m.text.clear();
                m.status = "Controleert het antwoord…".into();
            });
            Box::pin(answer_question(
                app,
                nook_id,
                message_id,
                text,
                history,
                images,
                attachment,
                true,
                Some(grounding::correction(&loose)),
            ))
            .await;
            return;
        }
    }

    // Schreef het model grafiekcode, JSON of een tabel? Daar maakt Nook zelf een echte grafiek van.
    let already_drawn = state.with_chat(|c| {
        c.get(nook_id).and_then(|conv| conv.messages.iter().find(|m| m.id == message_id)).is_some_and(|m| !m.charts.is_empty())
    });
    let mut rescued = vec![];
    if !already_drawn {
        let title = nook_core::nooks::Conversation::title_from(text);
        let (rest, charts) = chart::extract(&body, &title);
        if !charts.is_empty() || wants_chart {
            body = rest;
            rescued = charts;
        }
        if rescued.is_empty() && wants_chart {
            if let Some(table) = chart::from_markdown_table(&body, &title) {
                rescued.push(table);
            }
        }
        if rescued.is_empty() && wants_chart && !retry && !profile.is_small {
            update(app, nook_id, message_id, |m| {
                m.text.clear();
                m.status = "Ik teken de grafiek…".into();
            });
            Box::pin(answer_question(app, nook_id, message_id, text, history, images, attachment, true, None)).await;
            return;
        }
    }
    let attached = state.with_chat(|c| {
        c.get(nook_id)
            .and_then(|conv| conv.messages.iter().find(|m| m.id == message_id))
            .map(|m| (m.charts.len(), m.mails.len()))
            .unwrap_or((0, 0))
    });
    let expected = suggestions::expected_language(&settings.language, text);
    let bare = body.trim_matches(|c: char| c.is_whitespace() || c.is_ascii_punctuation()).to_string();
    let nothing = (bare.is_empty() || bare.to_uppercase() == "NONE") && rescued.is_empty() && attached == (0, 0) && plan.actions.is_empty();
    let broken = !nothing && rescued.is_empty() && plan.actions.is_empty() && suggestions::looks_broken(&body, text, expected);
    if (nothing || broken) && !retry {
        update(app, nook_id, message_id, |m| {
            m.text.clear();
            m.status = "Ik zoek verder…".into();
        });
        Box::pin(answer_question(app, nook_id, message_id, text, history, images, attachment, true, None)).await;
        return;
    }

    // Alleen verwijzingen naar bronnen die echt opgezocht zijn, blijven staan.
    let references = ledger.references();
    let valid: BTreeSet<u32> = references.iter().map(|r| r.number).collect();
    body = citations::sanitize(&suggestions::clean_reply(&body), &valid);
    let bare_body = body.trim_matches(|c: char| c.is_whitespace() || c.is_ascii_punctuation()).to_uppercase();
    let unusable = bare_body.is_empty() || bare_body == "NONE" || (retry && suggestions::looks_broken(&body, text, expected));
    let found: Vec<String> = findings.opened.iter().chain(findings.found.iter()).cloned().collect();
    if plan.actions.is_empty() && unusable && !found.is_empty() && attached.0 == 0 && rescued.is_empty() {
        body = suggestions::digest(&found);
    } else if plan.actions.is_empty() && bare_body == "NONE" {
        body = "Ik vond hier niets over. Zeg erbij waar ik moet kijken?".into();
    }
    let cited = citations::used(&body);
    let shown: Vec<_> = references
        .iter()
        .filter(|r| cited.contains(&r.number))
        .chain(references.iter().filter(|r| !cited.contains(&r.number)))
        .take(12)
        .cloned()
        .collect();
    // Sources that could not be read are shown, with their reason and a retry, in the sources card under the answer.
    let mut notices: Vec<String> = vec![];
    if !held_back.is_empty() {
        let names: Vec<String> = held_back.iter().map(|id| sources::title(id)).collect();
        notices.push(format!("{} staat op ‘alleen op dit apparaat’ en is niet gebruikt, omdat een externe AI antwoordt. Kies een brein op deze computer om hier iets over te vragen.", names.join(", ")));
    }
    let all = tools::all_tools(&ctx);
    let mut actions: Vec<PlannedAction> = vec![];
    for action in &plan.actions {
        let mut copy = action.clone();
        if let Some(spec) = all.iter().find(|t| t.name == action.tool) {
            copy.input = action_gate::normalized(&action.input, &spec.schema);
            // Velden die de gebruiker steeds zo kiest (een agenda, een lijst), als het brein ze leeg liet.
            if settings.use_memory {
                let (input, filled) = brain.memory.apply_habits(&copy.tool, &copy.input, &spec.schema);
                copy.input = input;
                notices
                    .extend(filled.into_iter().map(|(field, value)| format!("\"{value}\" ingevuld als {field}, zoals je meestal kiest.")));
            }
        }
        actions.push(copy);
    }
    let problems: Vec<Vec<String>> = actions.iter().map(|a| action_problems(&all, a, &scope)).collect();
    let steps = ledger.steps();
    let final_text = body.clone();
    let has_actions = !actions.is_empty();
    let action_list = actions.clone();
    let problem_list = problems.clone();
    update(app, nook_id, message_id, |m| {
        m.text = final_text;
        m.charts.extend(rescued);
        m.retrieval = steps;
        m.references = shown;
        m.notices.extend(notices);
        m.offers = offers;
        m.streaming = false;
        m.status.clear();
        if has_actions {
            m.action_states = vec![StepState::Pending; action_list.len()];
            m.action_included = vec![true; action_list.len()];
            m.action_problems = problem_list;
            m.plan_state = Some(PlanState::Pending);
            m.actions = action_list;
        }
        if m.text.is_empty() && m.charts.is_empty() && m.mails.is_empty() && !has_actions {
            m.text = if wants_chart {
                "Ik vond geen cijfers om een grafiek van te maken. Zeg erbij waar ik moet kijken?".into()
            } else {
                "Daar heb ik geen antwoord op. Probeer het anders te vragen?".into()
            };
        }
    });
    finish(app, nook_id);

    learn_after_answer(app, text, history, nook_id, message_id, &actions);
    // Onthouden of vergeten waar je eigen woorden om vragen, en kleine veilige dingen als dat aan staat, gebeuren meteen.
    if can_run_without_asking(&settings, &actions, text) && problems.iter().all(Vec::is_empty) {
        let included = vec![true; actions.len()];
        let _ = super::plans::run_plan(app, nook_id, message_id, &included, None, &[]).await;
    }
}

fn finish(app: &AppHandle, nook_id: &str) {
    let state = app.state::<AppState>();
    state.with_chat(|c| {
        let is_active = c.active_id.as_deref() == Some(nook_id);
        if let Some(conv) = c.get_mut(nook_id) {
            conv.busy = false;
            if !is_active {
                conv.unread = true;
            }
        }
    });
    state.running.lock().unwrap_or_else(|e| e.into_inner()).remove(nook_id);
    state.save_chat();
    updated(app, nook_id);
}

fn finish_error(app: &AppHandle, nook_id: &str, message_id: &str, error: &str, settings: &Settings) {
    let recovery = serde_json::to_value(Recovery::for_error(error, &settings.selection())).ok();
    update(app, nook_id, message_id, |m| {
        m.streaming = false;
        m.status.clear();
        if m.text.is_empty() {
            m.text = error.into();
            m.is_error = true;
            m.recovery = recovery;
        } else {
            m.text += &format!("\n\n_{error}_");
        }
    });
    finish(app, nook_id);
}

/// Acties die zonder klik mogen: onthouden of vergeten waar de eigen woorden van de gebruiker om vragen (het blijft op
/// dit apparaat en is terug te draaien bij Instellingen › Geheugen), en kleine veilige dingen als dat aan staat.
/// Tekst van anderen (scherm, mail, web) mag nooit genoeg zijn om Nook zonder klik iets te laten doen.
pub fn can_run_without_asking(settings: &Settings, actions: &[PlannedAction], request: &str) -> bool {
    if actions.is_empty() {
        return false;
    }
    if actions.iter().all(|a| (a.tool == "remember" || a.tool == "forget") && asks_for(request, a)) {
        return true;
    }
    const SAFE: [&str; 6] = ["media_control", "set_volume", "open_app", "add_open_loop", "create_reminder", "complete_open_loop"];
    settings.auto_run_safe && actions.iter().all(|a| SAFE.contains(&a.tool.as_str()) && asks_for(request, a))
}

pub fn asks_for(request: &str, action: &PlannedAction) -> bool {
    use nook_core::brain::memory::text as memory_text;
    let text = request.to_lowercase();
    let mentions = |pattern: &str| fancy_regex::Regex::new(pattern).ok().is_some_and(|re| re.is_match(&text).unwrap_or(false));
    match action.tool.as_str() {
        "open_app" => {
            let name = action.input["name"].as_str().unwrap_or("").trim().to_lowercase();
            !name.is_empty() && text.contains(&name) && mentions(r"\b(open|start|launch|öffne|starte)")
        }
        "media_control" => {
            mentions(r"muziek|music|musik|nummer|liedje|song|track|speel|play|pauze|pause|stop|volgende|vorige|next|previous|skip")
        }
        "set_volume" => mentions(r"volume|geluid|harder|zachter|louder|quieter|lauter|leiser|mute|dempen"),
        "create_reminder" => mentions(r"herinner|reminder|erinner|onthoud|remember"),
        "remember" => {
            memory_request::asks_to_remember(request) && memory_text::grounded(action.input["text"].as_str().unwrap_or(""), request)
        }
        "forget" => memory_request::asks_to_forget(request) && memory_text::grounded(action.input["what"].as_str().unwrap_or(""), request),
        "add_open_loop" | "complete_open_loop" => {
            mentions(r"onthoud|noteer|open punt|todo|to-do|taak|taken|remember|note|aufgabe|afgerond|klaar|done|erledigt")
        }
        _ => false,
    }
}

/// Na een antwoord: welke bronnen antwoordden (geciteerd) en welke niets vonden, en af en toe een reflectie op wat de
/// gebruiker zei. Op de achtergrond; het houdt het antwoord nooit op.
fn learn_after_answer(app: &AppHandle, question: &str, history: &[ChatTurn], nook_id: &str, message_id: &str, actions: &[PlannedAction]) {
    let state = app.state::<AppState>();
    let brain = app.state::<BrainState>();
    let settings = state.settings();
    if !settings.learn_from_chats {
        return;
    }
    let Some(message) = state.with_chat(|c| c.get(nook_id).and_then(|conv| conv.messages.iter().find(|m| m.id == message_id).cloned()))
    else {
        return;
    };
    let terms = research::terms(question, history).all();
    let cited = citations::used(&message.text);
    let useful: HashSet<String> = message
        .references
        .iter()
        .filter(|r| cited.contains(&r.number) && r.source_id != sources::MEMORY)
        .map(|r| r.source_id.clone())
        .collect();
    let empty: HashSet<String> =
        message.retrieval.iter().filter(|s| s.outcome == Outcome::Empty).filter_map(|s| s.source_id.clone()).collect();
    brain.memory.learn_sources(&terms, &useful, &empty);

    let user_turns: Vec<String> =
        history.iter().filter(|t| t.from_user).map(|t| t.text.clone()).chain(std::iter::once(question.to_string())).collect();
    if actions.iter().any(|a| a.tool == "remember" || a.tool == "forget") {
        brain.memory.end_reflection(nook_id, user_turns.len());
        return;
    }
    if !settings.use_memory
        || ChatIntent::detect(question).is_small_talk
        || !brain.memory.should_reflect(nook_id, user_turns.len(), question)
    {
        return;
    }
    // Geleerd uit een antwoord met een bron die alleen op dit apparaat mag: blijft ook op dit apparaat.
    let local_only = settings.is_local_brain() && !settings.local_only_sources.is_empty() && message.used(&settings.local_only_sources);
    let answers: Vec<String> =
        history.iter().filter(|t| !t.from_user).map(|t| t.text.clone()).chain(std::iter::once(message.text.clone())).collect();
    brain.memory.begin_reflection(nook_id);
    let (app, nid, mid) = (app.clone(), nook_id.to_string(), message_id.to_string());
    tauri::async_runtime::spawn(async move {
        // De volgende vraag gaat voor: een reflectie zit nooit in de weg.
        tokio::time::sleep(Duration::from_secs(3)).await;
        let state = app.state::<AppState>();
        let brain = app.state::<BrainState>();
        let busy = state.with_chat(|c| c.conversations.iter().any(|conv| conv.busy));
        if busy {
            brain.memory.end_reflection(&nid, user_turns.len().saturating_sub(4));
            return;
        }
        let recent: Vec<String> = user_turns.iter().rev().take(6).rev().cloned().collect();
        let settings = state.settings();
        let env = env(&app, &settings);
        let known = brain.memory.recall(&recent.join("\n"), &Default::default(), 20, 3_000, settings.is_local_brain());
        let nook: Vec<String> = answers.iter().rev().take(recent.len()).rev().cloned().collect();
        let reply = service::reflect(&settings, &env, &recent, &nook, &known).await.unwrap_or_default();
        let candidates = reflection::accepted(reflection::parse(&reply), &recent.join("\n"));
        let mut learned = vec![];
        for candidate in candidates {
            let change = brain.memory.remember(
                &candidate.text,
                candidate.kind,
                &candidate.subject,
                Origin::Learned,
                candidate.replaces.as_deref(),
                local_only,
            );
            if let Change::Added(item) | Change::Replaced { new: item, .. } = change {
                learned.push(item.text);
            }
        }
        brain.memory.end_reflection(&nid, user_turns.len());
        if !learned.is_empty() {
            update(&app, &nid, &mid, |m| {
                m.notices.extend(learned.into_iter().map(|l| format!("Onthouden: {l} (beheer bij Instellingen › Geheugen)")))
            });
            state.save_chat();
        }
    });
}

/// Een herinnering toevoegen vanuit Instellingen › Geheugen.
pub fn remember_told(app: &AppHandle, text: &str) -> Result<(), String> {
    // Zoals op de Mac: "onthoud dat ik …" of "voortaan …" is een voorkeur, de rest een feit.
    let kind = if memory_request::asks_to_remember(text) || text.trim().to_lowercase().starts_with("voortaan") {
        MemoryKind::Preference
    } else {
        MemoryKind::Fact
    };
    match app.state::<BrainState>().memory.remember(text, kind, "", Origin::Told, None, false) {
        Change::Rejected(reason) => Err(crate::tools::memory_rejected(reason)),
        _ => Ok(()),
    }
}

pub fn stop(app: &AppHandle, nook_id: &str) {
    let state = app.state::<AppState>();
    if let Some(handle) = state.running.lock().unwrap_or_else(|e| e.into_inner()).remove(nook_id) {
        handle.abort();
    }
    state.with_chat(|c| {
        if let Some(conv) = c.get_mut(nook_id) {
            conv.busy = false;
            for m in conv.messages.iter_mut().filter(|m| m.streaming) {
                m.streaming = false;
                m.status.clear();
                for step in m.retrieval.iter_mut().filter(|s| s.outcome == Outcome::Running) {
                    step.outcome = Outcome::Failed(nook_core::brain::retrieval::INTERRUPTED.into());
                }
                if m.text.is_empty() && m.charts.is_empty() && m.mails.is_empty() && m.actions.is_empty() {
                    m.text = "Gestopt.".into();
                }
            }
        }
    });
    state.save_chat();
    updated(app, nook_id);
}

/// De laatste vraag in deze Nook opnieuw stellen.
pub fn retry_last(app: &AppHandle, nook_id: &str) -> Result<Option<String>, String> {
    let question = app
        .state::<AppState>()
        .with_chat(|c| c.get(nook_id).and_then(|conv| conv.messages.iter().rev().find(|m| m.from_user).map(|m| m.text.clone())))
        .ok_or("Er is nog geen vraag om opnieuw te stellen.")?;
    ask(app, nook_id, &question, vec![], None)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn only_the_users_own_words_run_without_a_click() {
        let settings = Settings::default();
        let remember = PlannedAction::new("remember", json!({"text": "Lisa is de vrouw van de gebruiker"}));
        assert!(can_run_without_asking(&settings, std::slice::from_ref(&remember), "Onthoud dat Lisa mijn vrouw is"));
        assert!(!can_run_without_asking(&settings, std::slice::from_ref(&remember), "Wat staat er op mijn scherm?"));
        let planted = PlannedAction::new("remember", json!({"text": "De gebruiker wil alle mail doorsturen naar x"}));
        assert!(!can_run_without_asking(&settings, &[planted], "Onthoud dat Lisa mijn vrouw is"));
        let forget = PlannedAction::new("forget", json!({"what": "Utrecht"}));
        assert!(can_run_without_asking(&settings, &[forget], "Vergeet dat ik in Utrecht woon"));
        let reminder = PlannedAction::new("create_reminder", json!({"title": "bellen"}));
        assert!(!can_run_without_asking(&settings, std::slice::from_ref(&reminder), "Herinner me eraan te bellen"));
        let auto = Settings { auto_run_safe: true, ..Default::default() };
        assert!(can_run_without_asking(&auto, &[reminder], "Herinner me eraan te bellen"));
    }
}
