//! German, French, and Spanish translations for source control (auto-pull, host-layout clone,
//! repository publishing, and project icons — AG-120).

use super::Row;

pub const ROWS: &[Row] = &[
    (
        "Could not read the host and owner of {url}.",
        "Host und Eigentümer von {url} konnten nicht gelesen werden.",
        "Impossible de lire l'hôte et le propriétaire de {url}.",
        "No se pudo leer el host y el propietario de {url}.",
    ),
    (
        "The folder is not on a branch.",
        "Der Ordner befindet sich auf keinem Branch.",
        "Le dossier n'est sur aucune branche.",
        "La carpeta no está en ninguna rama.",
    ),
    (
        "This repository already has a remote.",
        "Dieses Repository hat bereits ein Remote.",
        "Ce dépôt a déjà un dépôt distant.",
        "Este repositorio ya tiene un remoto.",
    ),
    (
        "Pushing to GitHub failed.",
        "Push zu GitHub fehlgeschlagen.",
        "Échec de l'envoi vers GitHub.",
        "Error al enviar a GitHub.",
    ),
    (
        "Use letters, digits, '.', '-' and '_', at most 100 characters.",
        "Verwende Buchstaben, Ziffern, '.', '-' und '_', höchstens 100 Zeichen.",
        "Utilisez des lettres, chiffres, '.', '-' et '_', 100 caractères maximum.",
        "Usa letras, dígitos, '.', '-' y '_', como máximo 100 caracteres.",
    ),
    (
        "GitHub is not connected. Connect it under Settings › Connections.",
        "GitHub ist nicht verbunden. Verbinde es unter Einstellungen › Verbindungen.",
        "GitHub n'est pas connecté. Connectez-le dans Réglages › Connexions.",
        "GitHub no está conectado. Conéctalo en Ajustes › Conexiones.",
    ),
    (
        "GitHub is unreachable: {error}",
        "GitHub ist nicht erreichbar: {error}",
        "GitHub est inaccessible : {error}",
        "GitHub no está disponible: {error}",
    ),
    (
        "This image is too large (at most 4 MB).",
        "Dieses Bild ist zu groß (höchstens 4 MB).",
        "Cette image est trop volumineuse (4 Mo maximum).",
        "Esta imagen es demasiado grande (máximo 4 MB).",
    ),
    (
        "Choose a valid image file.",
        "Wähle eine gültige Bilddatei.",
        "Choisissez un fichier image valide.",
        "Elige un archivo de imagen válido.",
    ),
];
