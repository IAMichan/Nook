//! Agents wave 6: session concurrency cap (`SessionCapacity`, AG-75) and side chats (`/btw`, `/side`, AG-61).

use super::Row;

pub const ROWS: &[Row] = &[
    (
        "Waiting: {limit} sessions are already working. This turn starts as soon as one of them is done (Settings › Agents › Sessions).",
        "Wartet: Es arbeiten bereits {limit} Sitzungen. Dieser Durchgang startet, sobald eine fertig ist (Einstellungen › Agenten › Sitzungen).",
        "En attente : {limit} sessions travaillent déjà. Ce tour démarre dès que l'une d'elles a fini (Réglages › Agents › Sessions).",
        "En espera: ya trabajan {limit} sesiones. Este turno empieza en cuanto una termine (Ajustes › Agentes › Sesiones).",
    ),
    (
        "Stopped.",
        "Gestoppt.",
        "Arrêté.",
        "Detenido.",
    ),
    (
        "Ask a question after /btw or /side.",
        "Stelle eine Frage nach /btw oder /side.",
        "Pose une question après /btw ou /side.",
        "Haz una pregunta después de /btw o /side.",
    ),
    (
        "The side chat timed out.",
        "Das Nebengespräch hat zu lange gedauert.",
        "L'aparté a expiré.",
        "El chat lateral agotó el tiempo de espera.",
    ),
];
