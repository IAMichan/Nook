//! `session_start` with an account and rights per session (AG-05), and the bridge's card tools (`session_suggest`,
//! `render_page`, AG-07 and AG-08).

use super::Row;

pub const ROWS: &[Row] = &[
    ("Account {name}", "Konto {name}", "Compte {name}", "Cuenta {name}"),
    ("Ask for everything", "Alles fragen", "Tout demander", "Preguntar todo"),
    ("Allow edits", "Änderungen erlauben", "Autoriser les modifications", "Permitir ediciones"),
    ("Allow everything", "Alles erlauben", "Tout autoriser", "Permitir todo"),
    ("Suggest a session", "Sitzung vorschlagen", "Proposer une session", "Sugerir una sesión"),
    ("Show a page", "Seite anzeigen", "Afficher une page", "Mostrar una página"),
];
