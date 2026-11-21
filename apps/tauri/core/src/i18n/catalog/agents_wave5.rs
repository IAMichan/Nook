//! Agents wave 5: session goals (`/goal`, AG-67) and live compaction status (AG-65).

use super::Row;

pub const ROWS: &[Row] = &[
    (
        "Goal set: {goal}",
        "Ziel gesetzt: {goal}",
        "Objectif défini : {goal}",
        "Objetivo definido: {goal}",
    ),
    (
        "Goal cleared.",
        "Ziel gelöscht.",
        "Objectif effacé.",
        "Objetivo borrado.",
    ),
    (
        "Compacting the conversation stopped.",
        "Zusammenfassen der Unterhaltung abgebrochen.",
        "Résumé de la conversation interrompu.",
        "Se detuvo el resumen de la conversación.",
    ),
];
