//! Settings › Maintenance: the export dialog and its messages.

use super::Row;

pub const ROWS: &[Row] = &[
    ("Export settings", "Einstellungen exportieren", "Exporter les réglages", "Exportar ajustes"),
    ("Nook settings", "Nook-Einstellungen", "Réglages de Nook", "Ajustes de Nook"),
    (
        "Could not write the file: {error}",
        "Die Datei konnte nicht geschrieben werden: {error}",
        "Impossible d’écrire le fichier : {error}",
        "No se pudo escribir el archivo: {error}",
    ),
    (
        "Could not open the folder: {error}",
        "Der Ordner konnte nicht geöffnet werden: {error}",
        "Impossible d’ouvrir le dossier : {error}",
        "No se pudo abrir la carpeta: {error}",
    ),
];
