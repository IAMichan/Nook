//! WhatsApp's accounts and GOWA installed by Nook (`whatsapp.install.*` on the Mac).

use super::Row;

pub const ROWS: &[Row] = &[
    (
        "No GOWA build for this computer was found.",
        "Für diesen Computer wurde keine GOWA-Version gefunden.",
        "Aucune version de GOWA pour cet ordinateur n'a été trouvée.",
        "No se encontró ninguna versión de GOWA para este ordenador.",
    ),
    (
        "Downloading GOWA failed. Try again later.",
        "Der Download von GOWA ist fehlgeschlagen. Versuche es später erneut.",
        "Le téléchargement de GOWA a échoué. Réessayez plus tard.",
        "No se pudo descargar GOWA. Inténtalo más tarde.",
    ),
    (
        "GOWA published no checksum for this version; Nook installs nothing without one.",
        "GOWA hat für diese Version keine Prüfsumme veröffentlicht; Nook installiert nichts ohne.",
        "GOWA n'a publié aucune somme de contrôle pour cette version ; Nook n'installe rien sans elle.",
        "GOWA no publicó suma de verificación para esta versión; Nook no instala nada sin ella.",
    ),
    (
        "The download does not match GOWA's checksum. Nothing was installed.",
        "Die Datei stimmt nicht mit der Prüfsumme von GOWA überein. Nichts installiert.",
        "Le téléchargement ne correspond pas à la somme de contrôle de GOWA. Rien n'a été installé.",
        "La descarga no coincide con la suma de verificación de GOWA. No se instaló nada.",
    ),
    ("Unpacking GOWA failed.", "Entpacken von GOWA fehlgeschlagen.", "La décompression de GOWA a échoué.", "No se pudo descomprimir GOWA."),
];
