//! Rows added with `br-24-run-command`; a feature keeps its own catalog file (see `catalog/mod.rs`).

use super::Row;

pub const ROWS: &[Row] = &[
    ("review", "prüfen", "revue", "revisión"),
    ("No command was given.", "Es wurde kein Befehl angegeben.", "Aucune commande n'a été fournie.", "No se indicó ningún comando."),
    (
        "The folder does not exist: {folder}",
        "Der Ordner existiert nicht: {folder}",
        "Le dossier n'existe pas : {folder}",
        "La carpeta no existe: {folder}",
    ),
    (
        "Started in Nook's terminal: {command}. The output is there.",
        "Im Terminal von Nook gestartet: {command}. Die Ausgabe steht dort.",
        "Lancé dans le terminal de Nook : {command}. La sortie s'y trouve.",
        "Iniciado en el terminal de Nook: {command}. La salida está allí.",
    ),
    (
        "Terminals run on your computer, not on your phone.",
        "Terminals laufen auf deinem Computer, nicht auf deinem Telefon.",
        "Les terminaux tournent sur ton ordinateur, pas sur ton téléphone.",
        "Las terminales se ejecutan en tu ordenador, no en tu teléfono.",
    ),
];
