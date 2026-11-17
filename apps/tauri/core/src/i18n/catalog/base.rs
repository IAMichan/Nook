use super::Row;

pub const ROWS: &[Row] = &[
    ("Open Nook", "Nook öffnen", "Ouvrir Nook", "Abrir Nook"),
    ("Log in to {app}", "Bei {app} anmelden", "Connexion à {app}", "Iniciar sesión en {app}"),
    (
        "No pull requests recognized; write them as owner/name#number.",
        "Keine Pull Requests erkannt; schreibe sie als eigentümer/name#nummer.",
        "Aucune pull request reconnue ; écrivez-les sous la forme propriétaire/nom#numéro.",
        "No se reconoció ninguna pull request; escríbelas como propietario/nombre#número.",
    ),
    (
        "Too many pull requests at once ({count}); maximum {limit}.",
        "Zu viele Pull Requests auf einmal ({count}); maximal {limit}.",
        "Trop de pull requests à la fois ({count}) ; maximum {limit}.",
        "Demasiadas pull requests a la vez ({count}); máximo {limit}.",
    ),
    ("Not a pull request: {list}.", "Kein Pull Request: {list}.", "Pas une pull request : {list}.", "No es una pull request: {list}."),
    ("This draft no longer exists.", "Dieser Entwurf existiert nicht mehr.", "Ce brouillon n’existe plus.", "Este borrador ya no existe."),
];
