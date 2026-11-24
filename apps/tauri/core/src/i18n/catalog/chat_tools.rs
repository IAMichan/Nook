//! The brain's chat tools over the shared inbox (`tools/chats.rs`: `chat_inbox`, `chat_send`).

use super::Row;

pub const ROWS: &[Row] = &[
    ("{app} message to {to}: {message}", "{app}-Nachricht an {to}: {message}", "Message {app} à {to} : {message}", "Mensaje de {app} a {to}: {message}"),
    (
        "Nook can only read {app}; send the message to {chat} yourself.",
        "Nook kann {app} nur lesen; schick die Nachricht an {chat} selbst.",
        "Nook peut seulement lire {app} ; envoie toi-même le message à {chat}.",
        "Nook solo puede leer {app}; envía tú el mensaje a {chat}.",
    ),
];
