// Geen extra consolevenster op Windows in een release-build.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    nook_lib::run()
}
