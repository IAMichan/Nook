//! Rows added with `local_eval` (`SV-82`); a feature keeps its own catalog file (see `catalog/mod.rs`).

use super::Row;

pub const ROWS: &[Row] = &[
    ("base", "Basis", "base", "base"),
    ("evidence", "Belege", "preuves", "pruebas"),
    ("check", "Prüfung", "vérification", "comprobación"),
    (
        "A measurement is already running.",
        "Eine Messung läuft bereits.",
        "Une mesure est déjà en cours.",
        "Ya hay una medición en curso.",
    ),
];
