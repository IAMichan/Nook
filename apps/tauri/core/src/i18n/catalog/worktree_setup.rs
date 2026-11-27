//! German, French, and Spanish translations for worktree setup progress and blocking setup scripts (AG-94).

use super::Row;

pub const ROWS: &[Row] = &[
    (
        "Fetched the latest {base}",
        "Neuesten Stand von {base} abgerufen",
        "Dernière version de {base} récupérée",
        "Se trajo lo último de {base}",
    ),
    (
        "{base} was fetched less than two minutes ago",
        "{base} wurde vor weniger als zwei Minuten abgerufen",
        "{base} a été récupérée il y a moins de deux minutes",
        "{base} se trajo hace menos de dos minutos",
    ),
    (
        "{base} is a local branch: nothing to fetch",
        "{base} ist ein lokaler Branch: nichts abzurufen",
        "{base} est une branche locale : rien à récupérer",
        "{base} es una rama local: no hay nada que traer",
    ),
    (
        "Couldn't fetch {base}, so the worktree starts from the last fetched state: {message}",
        "{base} konnte nicht abgerufen werden, der Worktree beginnt beim zuletzt abgerufenen Stand: {message}",
        "Impossible de récupérer {base}, le worktree part du dernier état récupéré : {message}",
        "No se pudo traer {base}, así que el worktree parte del último estado traído: {message}",
    ),
    (
        "Branch {branch} from {base} in {path}",
        "Branch {branch} von {base} in {path}",
        "Branche {branch} depuis {base} dans {path}",
        "Rama {branch} desde {base} en {path}",
    ),
    (
        "Files checked out by Git",
        "Dateien von Git ausgecheckt",
        "Fichiers extraits par Git",
        "Archivos extraídos por Git",
    ),
    (
        "No setup script in nook.json (runOnWorktreeCreate)",
        "Kein Setup-Skript in nook.json (runOnWorktreeCreate)",
        "Aucun script de configuration dans nook.json (runOnWorktreeCreate)",
        "No hay script de configuración en nook.json (runOnWorktreeCreate)",
    ),
    (
        "{name} runs in a terminal beside the session",
        "{name} läuft in einem Terminal neben der Sitzung",
        "{name} tourne dans un terminal à côté de la session",
        "{name} se ejecuta en un terminal junto a la sesión",
    ),
    (
        "{name} runs in a terminal; the agent waits until it ends",
        "{name} läuft in einem Terminal; der Agent wartet, bis es endet",
        "{name} tourne dans un terminal ; l’agent attend qu’il se termine",
        "{name} se ejecuta en un terminal; el agente espera a que termine",
    ),
    (
        "Setup script started: {name}",
        "Setup-Skript gestartet: {name}",
        "Script de configuration lancé : {name}",
        "Script de configuración iniciado: {name}",
    ),
    (
        "Waiting for setup script: {name}",
        "Warte auf Setup-Skript: {name}",
        "En attente du script de configuration : {name}",
        "Esperando al script de configuración: {name}",
    ),
    (
        "Setup script '{name}' failed (exit code {code}).",
        "Setup-Skript '{name}' fehlgeschlagen (Exit-Code {code}).",
        "Le script de configuration « {name} » a échoué (code {code}).",
        "El script de configuración '{name}' falló (código {code}).",
    ),
    (
        "Setup script '{name}' was closed before it finished.",
        "Setup-Skript '{name}' wurde geschlossen, bevor es fertig war.",
        "Le script de configuration « {name} » a été fermé avant la fin.",
        "El script de configuración '{name}' se cerró antes de terminar.",
    ),
];
