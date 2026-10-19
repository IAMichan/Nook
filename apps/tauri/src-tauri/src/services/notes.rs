//! De Notetaker: neemt een gesprek op (je microfoon, en wat de computer afspeelt voor de anderen), schrijft het
//! transcript terwijl je praat, en daarna de samenvatting, kernpunten en to-do's met je eigen brein (`NoteTaker` op
//! de Mac). Het geluid blijft in het geheugen; elk stuk wordt na een pauze herkend en dan vergeten. Er komt geen bot
//! in het gesprek: vertel de anderen dat je notities maakt.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use chrono::Utc;
use nook_core::nooks::ChatMessage;
use nook_core::services::notes::{self as model, LiveChannel, Note, NoteStatus, TimedWord};
use nook_core::services::rewrite;
use serde::Serialize;
use tauri::{AppHandle, Manager};

use super::Services;
use crate::state::AppState;

struct Session {
    note: Note,
    mine: Arc<Mutex<LiveChannel>>,
    others: Arc<Mutex<LiveChannel>>,
    my_words: Arc<Mutex<Vec<TimedWord>>>,
    their_words: Arc<Mutex<Vec<TimedWord>>>,
    #[cfg(desktop)]
    recordings: Vec<crate::platform::audio::Recording>,
    running: Arc<std::sync::atomic::AtomicBool>,
}

#[derive(Default)]
pub struct NoteSession {
    current: Mutex<Option<Session>>,
    transcribing: Arc<AtomicUsize>,
    problem: Mutex<Option<String>>,
}

/// Wat de interface van de lopende opname ziet.
#[derive(Debug, Clone, Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct NoteLive {
    pub recording: bool,
    pub seconds: f64,
    pub level: f32,
    pub lines: usize,
    pub last: String,
    pub system_audio: bool,
    pub problem: Option<String>,
}

fn emit_live(app: &AppHandle) {
    super::emit(app, "note-live", live(app));
}

pub fn live(app: &AppHandle) -> NoteLive {
    let services = app.state::<Services>();
    let problem = services.note_session.problem.lock().unwrap_or_else(|e| e.into_inner()).clone();
    let guard = services.note_session.current.lock().unwrap_or_else(|e| e.into_inner());
    match guard.as_ref() {
        Some(s) => NoteLive {
            recording: true,
            seconds: s.note.duration(),
            level: s.mine.lock().unwrap_or_else(|e| e.into_inner()).level.max(s.others.lock().unwrap_or_else(|e| e.into_inner()).level),
            lines: s.note.lines.len(),
            last: s.note.lines.last().map(|l| l.text.clone()).unwrap_or_default(),
            system_audio: s.note.system_audio,
            problem,
        },
        None => NoteLive { problem, ..Default::default() },
    }
}

pub fn toggle(app: &AppHandle) {
    let recording = app.state::<Services>().note_session.current.lock().unwrap_or_else(|e| e.into_inner()).is_some();
    if recording {
        stop(app);
    } else if let Err(e) = start(app) {
        *app.state::<Services>().note_session.problem.lock().unwrap_or_else(|e| e.into_inner()) = Some(e);
        emit_live(app);
    }
}

pub fn start(app: &AppHandle) -> Result<(), String> {
    let services = app.state::<Services>();
    if services.note_session.current.lock().unwrap_or_else(|e| e.into_inner()).is_some() {
        return Ok(());
    }
    // De herkenning moet klaar zijn voor we iemand laten praten.
    super::voice::engine_ready(app, false)?;
    *services.note_session.problem.lock().unwrap_or_else(|e| e.into_inner()) = None;
    let mine: Arc<Mutex<LiveChannel>> = Arc::default();
    let others: Arc<Mutex<LiveChannel>> = Arc::default();
    let mut note = Note::new("Gesprek", Utc::now());
    note.app = services.platform.screen.active_app().map(|a| a.name);
    #[cfg(desktop)]
    let recordings = {
        let mut recordings = Vec::new();
        let sink = mine.clone();
        recordings
            .push(crate::platform::audio::microphone(Box::new(move |s: &[f32]| sink.lock().unwrap_or_else(|e| e.into_inner()).append(s)))?);
        let sink = others.clone();
        match crate::platform::audio::system_audio(Box::new(move |s: &[f32]| sink.lock().unwrap_or_else(|e| e.into_inner()).append(s))) {
            Ok(r) => {
                recordings.push(r);
                note.system_audio = true;
            }
            // Zonder het geluid van de computer: alleen jouw kant, en de kamer via de microfoon.
            Err(e) => {
                log::info!("Notetaker zonder systeemgeluid: {e}");
                *services.note_session.problem.lock().unwrap_or_else(|e| e.into_inner()) =
                    Some(format!("Alleen je microfoon wordt opgenomen: {e}"));
            }
        }
        recordings
    };
    #[cfg(not(desktop))]
    return Err("Opnemen kan op dit platform (nog) niet.".into());
    #[cfg(desktop)]
    {
        let running = Arc::new(std::sync::atomic::AtomicBool::new(true));
        *services.note_session.current.lock().unwrap_or_else(|e| e.into_inner()) = Some(Session {
            note,
            mine,
            others,
            my_words: Arc::default(),
            their_words: Arc::default(),
            recordings,
            running: running.clone(),
        });
        super::windows::show_badge(app, true);
        emit_live(app);
        let app = app.clone();
        std::thread::Builder::new()
            .name("nook-notetaker".into())
            .spawn(move || {
                while running.load(Ordering::SeqCst) {
                    std::thread::sleep(Duration::from_secs(1));
                    tick(&app, false);
                    emit_live(&app);
                }
            })
            .ok();
        Ok(())
    }
}

/// Stukken die klaar zijn naar de herkenning.
fn tick(app: &AppHandle, force: bool) {
    let services = app.state::<Services>();
    let jobs = {
        let guard = services.note_session.current.lock().unwrap_or_else(|e| e.into_inner());
        let Some(s) = guard.as_ref() else { return };
        let mut jobs = Vec::new();
        if let Some(chunk) = s.mine.lock().unwrap_or_else(|e| e.into_inner()).take_chunk(force) {
            jobs.push((chunk, s.my_words.clone()));
        }
        if let Some(chunk) = s.others.lock().unwrap_or_else(|e| e.into_inner()).take_chunk(force) {
            jobs.push((chunk, s.their_words.clone()));
        }
        jobs
    };
    for ((offset, samples), target) in jobs {
        let counter = services.note_session.transcribing.clone();
        counter.fetch_add(1, Ordering::SeqCst);
        let app = app.clone();
        tauri::async_runtime::spawn(async move {
            match super::voice::transcribe(&app, samples, offset).await {
                Ok((_, words)) => target.lock().unwrap_or_else(|e| e.into_inner()).extend(words),
                Err(e) => *app.state::<Services>().note_session.problem.lock().unwrap_or_else(|e| e.into_inner()) = Some(e),
            }
            counter.fetch_sub(1, Ordering::SeqCst);
            rebuild(&app);
        });
    }
}

fn rebuild(app: &AppHandle) {
    let services = app.state::<Services>();
    let mut guard = services.note_session.current.lock().unwrap_or_else(|e| e.into_inner());
    let Some(s) = guard.as_mut() else { return };
    let (mine, theirs) = sorted(&s.my_words, &s.their_words);
    let (speakers, lines) = model::build(&mine, &theirs, "Ik", "De anderen");
    s.note.speakers = speakers;
    s.note.lines = lines;
}

fn sorted(mine: &Mutex<Vec<TimedWord>>, theirs: &Mutex<Vec<TimedWord>>) -> (Vec<TimedWord>, Vec<TimedWord>) {
    let mut a = mine.lock().unwrap_or_else(|e| e.into_inner()).clone();
    let mut b = theirs.lock().unwrap_or_else(|e| e.into_inner()).clone();
    a.sort_by(|x, y| x.start.total_cmp(&y.start));
    b.sort_by(|x, y| x.start.total_cmp(&y.start));
    (a, b)
}

pub fn stop(app: &AppHandle) {
    let services = app.state::<Services>();
    let Some(mut session) = services.note_session.current.lock().unwrap_or_else(|e| e.into_inner()).take() else { return };
    session.running.store(false, Ordering::SeqCst);
    #[cfg(desktop)]
    for mut recording in session.recordings.drain(..) {
        recording.stop();
    }
    // Het laatste stuk nog naar de herkenning.
    let last: Vec<_> = [(session.mine.clone(), session.my_words.clone()), (session.others.clone(), session.their_words.clone())]
        .into_iter()
        .filter_map(|(channel, words)| channel.lock().unwrap_or_else(|e| e.into_inner()).take_chunk(true).map(|c| (c, words)))
        .collect();
    #[cfg(desktop)]
    super::windows::show_badge(app, false);
    session.note.end = Some(Utc::now());
    session.note.status = NoteStatus::Processing;
    emit_live(app);
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        for ((offset, samples), target) in last {
            if let Ok((_, words)) = super::voice::transcribe(&app, samples, offset).await {
                target.lock().unwrap_or_else(|e| e.into_inner()).extend(words);
            }
        }
        // Stukken die nog herkend worden, krijgen even.
        let counter = app.state::<Services>().note_session.transcribing.clone();
        for _ in 0..240 {
            if counter.load(Ordering::SeqCst) == 0 {
                break;
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
        let (mine, theirs) = sorted(&session.my_words, &session.their_words);
        finish(&app, session.note, mine, theirs).await;
    });
}

async fn finish(app: &AppHandle, mut note: Note, mine: Vec<TimedWord>, theirs: Vec<TimedWord>) {
    let (speakers, lines) = model::build(&mine, &theirs, "Ik", "De anderen");
    note.speakers = speakers;
    note.lines = lines;
    let services = app.state::<Services>();
    if note.lines.is_empty() {
        note.status = NoteStatus::Failed;
        note.error = Some("Er is niets verstaan. Stond de microfoon aan?".into());
        services.notes.lock().unwrap_or_else(|e| e.into_inner()).save(&note);
        emit_live(app);
        return;
    }
    services.notes.lock().unwrap_or_else(|e| e.into_inner()).save(&note);
    let settings = app.state::<AppState>().settings();
    let key = app.state::<AppState>().key_for(settings.provider);
    let transcript: String = model::plain_transcript(&note).chars().take(200_000).collect();
    let reply =
        rewrite::complete(&settings, key, model::SUMMARY_INSTRUCTIONS, &format!("<transcript>\n{transcript}\n</transcript>"), 2048).await;
    match reply {
        Ok(reply) => match model::parse_summary(&reply) {
            Some(summary) => {
                if let Some(title) = summary.title {
                    note.title = title;
                }
                note.summary = Some(summary.summary);
                note.key_points = summary.key_points;
                note.todos = summary.todos;
            }
            None => note.summary = Some(reply.trim().to_string()),
        },
        Err(e) => note.error = Some(format!("De samenvatting lukte niet: {e}")),
    }
    note.status = NoteStatus::Ready;
    services.notes.lock().unwrap_or_else(|e| e.into_inner()).save(&note);
    emit_live(app);
    show_in_chat(app, &note);
    services.platform.system.notify("Gesprek genoteerd", &note.title);
}

/// De notitie in een eigen Nook: samenvatting, kernpunten en to-do's, met het voorstel ze als open punten te bewaren.
fn show_in_chat(app: &AppHandle, note: &Note) {
    let state = app.state::<AppState>();
    let id = state.with_chat(|c| c.new_conversation());
    let mut body = model::markdown(note);
    if let Some(cut) = body.find("## Transcript") {
        body.truncate(cut);
    }
    let mut message = ChatMessage::nook(body.trim());
    message.sources = vec![format!("Gesprek van {}", note.start.with_timezone(&chrono::Local).format("%H:%M"))];
    if !note.todos.is_empty() {
        message.actions = note
            .todos
            .iter()
            .map(|t| nook_core::brain::PlannedAction::new("add_open_loop", serde_json::json!({"title": t.text})))
            .collect();
        message.action_included = vec![true; message.actions.len()];
        message.action_states = vec![nook_core::nooks::StepState::Pending; message.actions.len()];
        message.plan_state = Some(nook_core::nooks::PlanState::Pending);
    }
    state.with_chat(|c| {
        c.push(&id, message);
        if let Some(conv) = c.get_mut(&id) {
            conv.title = note.title.clone();
            conv.unread = true;
        }
    });
    state.save_chat();
    super::emit(app, "nook-updated", id);
}
