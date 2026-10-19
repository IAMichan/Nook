// Geen extra consolevenster op Windows in een release-build.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    // `nook --hook` en `nook --mcp` (of via `~/.nook/nook-hook` en `~/.nook/nook-mcp`): hulpstand voor agents, zonder vensters.
    if let Some(code) = nook_lib::cli::dispatch() {
        std::process::exit(code);
    }
    nook_lib::run()
}
