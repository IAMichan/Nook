//! The clone notices in the main window (`CloneNoticeStack`, `GitCloneProgress` on the Mac: `clone.*`).

use super::Row;

pub const ROWS: &[Row] = &[
    ("Counting objects", "Objekte werden gezählt", "Comptage des objets", "Contando objetos"),
    ("Receiving objects", "Objekte werden empfangen", "Réception des objets", "Recibiendo objetos"),
    ("Resolving deltas", "Deltas werden aufgelöst", "Résolution des deltas", "Resolviendo deltas"),
    ("Checking out files", "Dateien werden ausgecheckt", "Extraction des fichiers", "Extrayendo archivos"),
    ("This repository is being cloned already.", "Dieses Repository wird bereits geklont.", "Ce dépôt est déjà en cours de clonage.", "Este repositorio ya se está clonando."),
    ("The folder {path} already exists.", "Der Ordner {path} existiert bereits.", "Le dossier {path} existe déjà.", "La carpeta {path} ya existe."),
    ("Stopped cloning {name}", "Klonen von {name} abgebrochen", "Clonage de {name} arrêté", "Se detuvo la clonación de {name}"),
    ("Cloning failed.", "Klonen fehlgeschlagen.", "Échec du clonage.", "La clonación falló."),
];
