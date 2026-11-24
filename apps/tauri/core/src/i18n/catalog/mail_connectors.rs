//! German, French, and Spanish translations for Microsoft & Google mail and calendar connectors.

use super::Row;

pub const ROWS: &[Row] = &[
    (
        "No refresh token received. Sign in again.",
        "Kein Aktualisierungstoken erhalten. Melde dich erneut an.",
        "Aucun jeton d'actualisation reçu. Reconnectez-vous.",
        "No se recibió ningún token de actualización. Inicia sesión de nuevo.",
    ),
    (
        "Could not read the email address for this account.",
        "Die E-Mail-Adresse für dieses Konto konnte nicht gelesen werden.",
        "Impossible de lire l'adresse e-mail de ce compte.",
        "No se pudo leer la dirección de correo electrónico de esta cuenta.",
    ),
    (
        "This mail account no longer exists.",
        "Dieses E-Mail-Konto existiert nicht mehr.",
        "Ce compte de messagerie n'existe plus.",
        "Esta cuenta de correo ya no existe.",
    ),
    (
        "No Microsoft client ID is configured. Enter your own client ID in Settings first.",
        "Keine Microsoft-Client-ID eingerichtet. Gib zuerst deine eigene Client-ID in den Einstellungen ein.",
        "Aucun identifiant client Microsoft n'est configuré. Saisissez d'abord votre propre identifiant client dans les réglages.",
        "No hay ningún ID de cliente de Microsoft configurado. Introduce primero tu propio ID de cliente en Ajustes.",
    ),
    (
        "Microsoft returned no refresh token. Try signing in again.",
        "Microsoft hat kein Aktualisierungstoken zurückgegeben. Melde dich erneut an.",
        "Microsoft n'a renvoyé aucun jeton d'actualisation. Essayez de vous reconnecter.",
        "Microsoft no devolvió ningún token de actualización. Intenta iniciar sesión de nuevo.",
    ),
    (
        "Google returned no refresh token. Try signing in again.",
        "Google hat kein Aktualisierungstoken zurückgegeben. Melde dich erneut an.",
        "Google n'a renvoyé aucun jeton d'actualisation. Essayez de vous reconnecter.",
        "Google no devolvió ningún token de actualización. Intenta iniciar sesión de nuevo.",
    ),
    (
        "No token found for {account}. Sign in again in Settings › Accounts & connections.",
        "Kein Token für {account} gefunden. Melde dich unter Einstellungen › Konten & Verbindungen erneut an.",
        "Aucun jeton trouvé pour {account}. Reconnectez-vous dans Réglages › Comptes et connexions.",
        "No se encontró ningún token para {account}. Inicia sesión de nuevo en Ajustes › Cuentas y conexiones.",
    ),
    (
        "No linked mail account matches \"{hint}\".",
        "Kein verknüpftes E-Mail-Konto passt zu \"{hint}\".",
        "Aucun compte de messagerie connecté ne correspond à « {hint} ».",
        "Ninguna cuenta de correo vinculada coincide con \"{hint}\".",
    ),
    (
        "No linked mail account with calendar sync enabled.",
        "Kein verknüpftes E-Mail-Konto mit aktivierter Kalendersynchronisierung.",
        "Aucun compte de messagerie connecté avec la synchronisation du calendrier activée.",
        "No hay ninguna cuenta de correo vinculada con la sincronización de calendario activada.",
    ),
    (
        "Mail & calendar",
        "E-Mail & Kalender",
        "E-mail et calendrier",
        "Correo y calendario",
    ),
    (
        "Mail is not available right now.",
        "E-Mail ist gerade nicht verfügbar.",
        "La messagerie n'est pas disponible pour le moment.",
        "El correo no está disponible en este momento.",
    ),
    (
        "Calendar is not available right now.",
        "Der Kalender ist gerade nicht verfügbar.",
        "Le calendrier n'est pas disponible pour le moment.",
        "El calendario no está disponible en este momento.",
    ),
    (
        "Could not read attachment \"{name}\": {error}",
        "Anhang \"{name}\" konnte nicht gelesen werden: {error}",
        "Impossible de lire la pièce jointe « {name} » : {error}",
        "No se pudo leer el archivo adjunto \"{name}\": {error}",
    ),
    (
        "Connections are not ready yet.",
        "Verbindungen sind noch nicht bereit.",
        "Les connexions ne sont pas encore prêtes.",
        "Las conexiones aún no están listas.",
    ),
    (
        "This sign-in code has expired. Start again.",
        "Dieser Anmeldecode ist abgelaufen. Beginne erneut.",
        "Ce code de connexion a expiré. Recommencez.",
        "Este código de inicio de sesión ha caducado. Vuelve a empezar.",
    ),
    (
        "Enter a recipient first.",
        "Gib zuerst einen Empfänger ein.",
        "Saisissez d'abord un destinataire.",
        "Introduce primero un destinatario.",
    ),
    (
        "{address} is not a valid email address.",
        "{address} ist keine gültige E-Mail-Adresse.",
        "{address} n'est pas une adresse e-mail valide.",
        "{address} no es una dirección de correo electrónico válida.",
    ),
];
