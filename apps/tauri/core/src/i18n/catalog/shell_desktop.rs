//! The tray tooltip, the first-close note, the quit question and the shortcut warning (`platform/desktop.rs`).

use super::Row;

pub const ROWS: &[Row] = &[
    ("Shortcut: {name}", "Kurzbefehl: {name}", "Raccourci : {name}", "Atajo: {name}"),
    ("{name} has not answered yet", "{name} hat noch nicht geantwortet", "{name} n'a pas encore répondu", "{name} aún no ha respondido"),
    ("Nook keeps running", "Nook läuft weiter", "Nook continue de tourner", "Nook sigue en marcha"),
    (
        "Nook stays at the top of your screen and in the system tray. Alt+Ctrl+W opens the window again; quit from the system tray.",
        "Nook bleibt oben am Bildschirm und im Infobereich. Alt+Strg+W öffnet das Fenster wieder; beenden kannst du es über den Infobereich.",
        "Nook reste en haut de votre écran et dans la zone de notification. Alt+Ctrl+W rouvre la fenêtre ; pour quitter, passez par la zone de notification.",
        "Nook se queda en la parte superior de la pantalla y en la bandeja del sistema. Alt+Ctrl+W vuelve a abrir la ventana; para salir, usa la bandeja del sistema.",
    ),
    ("Nook · working on {n}", "Nook · arbeitet an {n}", "Nook · travaille sur {n}", "Nook · trabajando en {n}"),
    ("Nook · 1 Nook is waiting for you", "Nook · 1 Nook wartet auf dich", "Nook · 1 Nook vous attend", "Nook · 1 Nook te espera"),
    ("Nook · {n} Nooks are waiting for you", "Nook · {n} Nooks warten auf dich", "Nook · {n} Nooks vous attendent", "Nook · {n} Nooks te esperan"),
    ("A session is still working", "Eine Sitzung arbeitet noch", "Une session travaille encore", "Una sesión sigue trabajando"),
    ("{n} sessions are still working", "{n} Sitzungen arbeiten noch", "{n} sessions travaillent encore", "{n} sesiones siguen trabajando"),
    (
        "Quitting Nook stops them. You can continue them after you open Nook again.",
        "Wenn du Nook beendest, stoppen sie auch. Du kannst sie fortsetzen, sobald du Nook wieder öffnest.",
        "Quitter Nook les arrête. Vous pourrez les reprendre en rouvrant Nook.",
        "Al salir de Nook se detienen. Podrás continuarlas cuando vuelvas a abrir Nook.",
    ),
    ("Quit Anyway", "Trotzdem beenden", "Quitter quand même", "Salir de todos modos"),
    ("Shortcut {accelerator} could not be registered: {e}", "Kurzbefehl {accelerator} konnte nicht registriert werden: {e}", "Le raccourci {accelerator} n’a pas pu être enregistré : {e}", "No se pudo registrar el atajo {accelerator}: {e}"),
    ("This file no longer exists.", "Diese Datei gibt es nicht mehr.", "Ce fichier n’existe plus.", "Este archivo ya no existe."),
];
