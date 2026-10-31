//! Gamer Mode: Nook as a coach that watches a game from the outside (screenshots of your own screen, read by your
//! own brain), remembers what happened earlier in the match, and points out what the other side keeps repeating.
//!
//! Each game is a submodule with its own catalog, match memory, and analysis. The list of supported games is
//! [`supported`]; adding a game is a new submodule and one entry there. Nothing here reads game memory or sends input
//! to a game: Nook only looks at what is on the screen, like a friend watching over your shoulder.

pub mod valorant;

use serde::Serialize;

/// A game Gamer Mode can coach, for the list on the Gamer Mode page.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GameInfo {
    /// Stable id, also the route of its coach in the interface (`valorant`).
    pub id: &'static str,
    pub title: &'static str,
    /// Executable names (lowercase) of the running game, to know when it is in front.
    pub processes: &'static [&'static str],
}

pub fn supported() -> Vec<GameInfo> {
    vec![GameInfo { id: valorant::GAME_ID, title: "Valorant", processes: valorant::PROCESSES }]
}

/// The game whose process `exe` is (case-insensitive, with or without `.exe`).
pub fn game_for_process(exe: &str) -> Option<GameInfo> {
    let exe = exe.trim().to_ascii_lowercase();
    let exe = exe.strip_suffix(".exe").unwrap_or(&exe);
    supported().into_iter().find(|g| g.processes.iter().any(|p| p.strip_suffix(".exe").unwrap_or(p) == exe))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_the_game_by_its_process() {
        assert_eq!(game_for_process("VALORANT-Win64-Shipping.exe").map(|g| g.id), Some("valorant"));
        assert_eq!(game_for_process("valorant-win64-shipping").map(|g| g.id), Some("valorant"));
        assert!(game_for_process("notepad.exe").is_none());
    }
}
