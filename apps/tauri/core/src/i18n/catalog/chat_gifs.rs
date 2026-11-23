//! GIFs from GIPHY in a chat's "+" (`chat.compose.gifs.*`, `chats.giphy.*` on the Mac).

use super::Row;

pub const ROWS: &[Row] = &[
    ("Add a GIPHY key to search GIFs.", "Füge einen GIPHY-Schlüssel hinzu, um GIFs zu suchen.", "Ajoutez une clé GIPHY pour chercher des GIF.", "Añade una clave de GIPHY para buscar GIF."),
    ("No connection to GIPHY.", "Keine Verbindung zu GIPHY.", "Pas de connexion à GIPHY.", "Sin conexión con GIPHY."),
    ("GIPHY gave no GIFs: {why}", "GIPHY lieferte keine GIFs: {why}", "GIPHY n’a renvoyé aucun GIF : {why}", "GIPHY no devolvió GIF: {why}"),
    ("No GIFs found.", "Keine GIFs gefunden.", "Aucun GIF trouvé.", "No se encontraron GIF."),
    ("The GIF could not be fetched.", "Das GIF konnte nicht geladen werden.", "Le GIF n'a pas pu être récupéré.", "No se pudo obtener el GIF."),
    ("The GIPHY key could not be saved", "Der GIPHY-Schlüssel konnte nicht gesichert werden", "La clé GIPHY n’a pas pu être enregistrée", "No se pudo guardar la clave de GIPHY"),
    ("This app cannot take a poll from Nook.", "Diese App kann von Nook keine Umfrage empfangen.", "Cette app ne peut pas recevoir de sondage depuis Nook.", "Esta app no puede recibir una encuesta desde Nook."),
    ("The vote did not go through.", "Die Stimme ist nicht angekommen.", "Le vote n’est pas passé.", "El voto no se registró."),
];
