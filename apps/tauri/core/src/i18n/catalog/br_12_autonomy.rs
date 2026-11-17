//! Rows added with `br-12-autonomy`; a feature keeps its own catalog file (see `catalog/mod.rs`).

use super::Row;

pub const ROWS: &[Row] = &[
    ("Ask me", "Mich fragen", "Me demander", "Preguntarme"),
    ("Nook decides", "Nook entscheidet", "Nook décide", "Nook decide"),
    ("Do it", "Einfach machen", "Le faire", "Hacerlo"),
    ("past the limit for one run", "über der Grenze für einen Lauf", "au-delà de la limite d’une exécution", "por encima del límite de una ejecución"),
    ("always waits for you", "wartet immer auf dich", "t’attend toujours", "siempre te espera"),
    ("Nook did 1 step by itself.", "Nook hat 1 Schritt selbst erledigt.", "Nook a fait 1 étape seul.", "Nook hizo 1 paso por sí solo."),
    ("Nook did {n} steps by itself.", "Nook hat {n} Schritte selbst erledigt.", "Nook a fait {n} étapes seul.", "Nook hizo {n} pasos por sí solo."),
    (
        "{n} steps failed; you can try them again above.",
        "{n} Schritte sind fehlgeschlagen; du kannst sie oben erneut versuchen.",
        "{n} étapes ont échoué ; tu peux les relancer plus haut.",
        "{n} pasos fallaron; puedes reintentarlos arriba.",
    ),
    ("Waiting for you ({n}):", "Wartet auf dich ({n}):", "En attente de toi ({n}) :", "Esperando por ti ({n}):"),
    ("Carried out by itself ({level})", "Selbst erledigt ({level})", "Fait seul ({level})", "Hecho por sí solo ({level})"),
    ("as soon as a new message arrives", "sobald eine neue Nachricht eingeht", "dès qu’un nouveau message arrive", "en cuanto llega un mensaje nuevo"),
    ("in {apps}", "in {apps}", "dans {apps}", "en {apps}"),
    ("from {from}", "von {from}", "de {from}", "de {from}"),
    ("about {words}", "über {words}", "sur {words}", "sobre {words}"),
    ("group chats too", "auch Gruppenchats", "aussi les groupes", "también chats de grupo"),
];
