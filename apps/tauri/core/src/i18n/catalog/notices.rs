//! System notifications (Windows toasts): their buttons and hints, in the Mac's words (`button.*`, `noticeDelivery.*`).

use super::Row;

pub const ROWS: &[Row] = &[
    ("Allow", "Erlauben", "Autoriser", "Permitir"),
    ("Always", "Immer", "Toujours", "Siempre"),
    ("Deny", "Ablehnen", "Refuser", "Denegar"),
    ("Show", "Ansehen", "Voir", "Ver"),
    ("Mark as read", "Als gelesen markieren", "Marquer comme lu", "Marcar como leído"),
    ("Send", "Senden", "Envoyer", "Enviar"),
    ("Type a reply…", "Antwort eingeben …", "Saisissez une réponse…", "Escribe una respuesta…"),
    (
        "Look at this in Nook before you allow it.",
        "Sieh dir das in Nook an, bevor du es erlaubst.",
        "Regarde ceci dans Nook avant de l’autoriser.",
        "Revísalo en Nook antes de permitirlo.",
    ),
    ("{agent} is done", "{agent} ist fertig", "{agent} a terminé", "{agent} ha terminado"),
    (
        "{agent} stopped with an error",
        "{agent} wurde mit einem Fehler beendet",
        "{agent} s’est arrêté sur une erreur",
        "{agent} se detuvo con un error",
    ),
    ("{agent} is waiting on you", "{agent} wartet auf dich", "{agent} t’attend", "{agent} te está esperando"),
];
