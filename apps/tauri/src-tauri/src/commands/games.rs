//! The commands of Gamer Mode: the list of games, and the Valorant Coach (its match memory, logging an event by
//! hand, and looking at the screen now).

use chrono::Utc;
use nook_core::games::valorant::catalog::{self, Agent};
use nook_core::games::valorant::memory::{EventInput, GamerPrefs};
use nook_core::games::{self, GameInfo};
use serde::Serialize;
use tauri::{AppHandle, State};

use crate::games::{self as gamer, CoachView, Gamer};

type Res<T> = Result<T, String>;

#[tauri::command]
pub fn games_list() -> Vec<GameInfo> {
    games::supported()
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ValorantCatalog {
    agents: &'static [Agent],
    maps: &'static [&'static str],
}

#[tauri::command]
pub fn valorant_catalog() -> ValorantCatalog {
    ValorantCatalog { agents: catalog::AGENTS, maps: catalog::MAPS }
}

#[tauri::command]
pub fn valorant_view(gamer: State<'_, Gamer>) -> CoachView {
    gamer.view()
}

fn update(app: &AppHandle, gamer: &Gamer, f: impl FnOnce(&mut nook_core::games::valorant::memory::ValorantStore)) -> CoachView {
    gamer.with_store(f);
    gamer::changed(app);
    gamer.view()
}

#[tauri::command]
pub fn valorant_save_prefs(app: AppHandle, gamer: State<'_, Gamer>, prefs: GamerPrefs) -> CoachView {
    update(&app, &gamer, |s| s.prefs = prefs)
}

#[tauri::command]
pub fn valorant_start_match(app: AppHandle, gamer: State<'_, Gamer>, map: Option<String>, agent: Option<String>) -> CoachView {
    update(&app, &gamer, |s| {
        s.start_match(map, agent, Utc::now());
    })
}

#[tauri::command]
pub fn valorant_end_match(app: AppHandle, gamer: State<'_, Gamer>) -> CoachView {
    update(&app, &gamer, |s| s.end_match(Utc::now()))
}

/// Sets the map and my agent of the match in progress (empty clears it).
#[tauri::command]
pub fn valorant_set_match(app: AppHandle, gamer: State<'_, Gamer>, map: Option<String>, agent: Option<String>) -> CoachView {
    update(&app, &gamer, |s| {
        let m = s.current_or_start(Utc::now());
        m.map = map.as_deref().and_then(catalog::map).map(String::from);
        m.my_agent = agent.as_deref().and_then(catalog::agent).map(|a| a.id.to_string());
    })
}

#[tauri::command]
pub fn valorant_next_round(app: AppHandle, gamer: State<'_, Gamer>) -> CoachView {
    update(&app, &gamer, |s| {
        let m = s.current_or_start(Utc::now());
        m.advance_to(m.current_round() + 1, Utc::now());
    })
}

#[tauri::command]
pub fn valorant_record(app: AppHandle, gamer: State<'_, Gamer>, input: EventInput) -> Res<CoachView> {
    let mut ok = false;
    let view = update(&app, &gamer, |s| ok = s.current_or_start(Utc::now()).record(input, Utc::now()).is_some());
    if ok {
        Ok(view)
    } else {
        Err("That agent, ability, or place is not one Nook knows.".into())
    }
}

#[tauri::command]
pub fn valorant_remove(app: AppHandle, gamer: State<'_, Gamer>, id: String) -> CoachView {
    update(&app, &gamer, |s| {
        if let Some(m) = s.current.as_mut() {
            m.remove(&id);
        }
    })
}

/// Looks at the screen now, whether or not the game is in front.
#[tauri::command]
pub async fn valorant_look(app: AppHandle) -> Res<usize> {
    gamer::look(&app).await
}
