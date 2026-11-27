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
    (
        "That is not a valid host or the token is empty.",
        "Das ist kein gültiger Host oder das Token ist leer.",
        "Cet hôte n'est pas valide ou le jeton est vide.",
        "Ese host no es válido o el token está vacío.",
    ),
    (
        "The code host rejected this token. Check that it has the right scopes and has not expired.",
        "Der Code-Host hat dieses Token abgelehnt. Prüfe, ob es die richtigen Berechtigungen hat und nicht abgelaufen ist.",
        "L'hébergeur de code a refusé ce jeton. Vérifiez qu'il dispose des bonnes autorisations et qu'il n'est pas expiré.",
        "El servidor de código rechazó este token. Comprueba que tenga los permisos adecuados y que no haya caducado.",
    ),
    (
        "No token is stored in your keychain for this host.",
        "Für diesen Host ist kein Token in deinem Schlüsselbund gespeichert.",
        "Aucun jeton n'est enregistré dans votre trousseau pour cet hôte.",
        "No hay ningún token guardado en tu llavero para este servidor.",
    ),
    (
        "Merge request opened: {url}",
        "Merge Request geöffnet: {url}",
        "Merge request ouverte : {url}",
        "Merge request abierto: {url}",
    ),
];
