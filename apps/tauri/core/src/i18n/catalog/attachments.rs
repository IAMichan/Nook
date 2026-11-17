//! Attachments in the chat: zip archives, folders and paths (`attachments`).

use super::Row;

pub const ROWS: &[Row] = &[
    (
        "{name} is not a zip file Nook can open, or it is damaged.",
        "{name} ist keine Zip-Datei, die Nook öffnen kann, oder sie ist beschädigt.",
        "{name} n’est pas un fichier zip que Nook peut ouvrir, ou il est endommagé.",
        "{name} no es un archivo zip que Nook pueda abrir, o está dañado.",
    ),
    (
        "{name} is larger than 500 MB unpacked. Unpack it yourself and attach the files you need.",
        "{name} ist entpackt größer als 500 MB. Entpacke es selbst und füge die Dateien hinzu, die du brauchst.",
        "{name} dépasse 500 Mo une fois décompressé. Décompressez-le vous-même et joignez les fichiers dont vous avez besoin.",
        "{name} ocupa más de 500 MB descomprimido. Descomprímelo tú y adjunta los archivos que necesites.",
    ),
    (
        "Nook found no files in {name}.",
        "Nook hat keine Dateien in {name} gefunden.",
        "Nook n’a trouvé aucun fichier dans {name}.",
        "Nook no encontró archivos en {name}.",
    ),
    (
        "Nook only reads files in your home folder (not in hidden folders or app data).",
        "Nook liest nur Dateien in deinem Benutzerordner (nicht in versteckten Ordnern oder App-Daten).",
        "Nook ne lit que les fichiers de votre dossier personnel (pas dans les dossiers cachés ni les données d’apps).",
        "Nook solo lee archivos de tu carpeta personal (no en carpetas ocultas ni datos de apps).",
    ),
    (
        "{name} is too large (more than 25 MB).",
        "{name} ist zu groß (mehr als 25 MB).",
        "{name} est trop volumineux (plus de 25 Mo).",
        "{name} es demasiado grande (más de 25 MB).",
    ),
];
