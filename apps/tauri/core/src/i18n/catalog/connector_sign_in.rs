//! German, French, and Spanish translations for MCP connector sign-in timeline messages (AG-31).

use super::Row;

pub const ROWS: &[Row] = &[
    (
        "{title} is connected. The agent can use it from your next message.",
        "{title} ist verbunden. Der Agent kann ihn ab deiner nächsten Nachricht nutzen.",
        "{title} est connecté. L'agent peut l'utiliser dès ton prochain message.",
        "{title} está conectado. El agente puede usarlo desde tu próximo mensaje.",
    ),
    (
        "Signing in to {title} did not work: {error}",
        "Anmeldung bei {title} fehlgeschlagen: {error}",
        "La connexion à {title} a échoué : {error}",
        "No se pudo iniciar sesión en {title}: {error}",
    ),
    (
        "the agent gave no sign-in page",
        "der Agent hat keine Anmeldeseite geliefert",
        "l'agent n'a fourni aucune page de connexion",
        "el agente no dio ninguna página de inicio de sesión",
    ),
    (
        "the agent is not running",
        "der Agent läuft nicht",
        "l'agent ne tourne pas",
        "el agente no se está ejecutando",
    ),
    (
        "{title} is no longer needed: the agent dropped this connector, or another connector covers the same service.",
        "{title} wird nicht mehr gebraucht: Der Agent hat diesen Connector nicht mehr, oder ein anderer Connector deckt denselben Dienst ab.",
        "{title} n'est plus nécessaire : l'agent n'a plus ce connecteur, ou un autre connecteur couvre le même service.",
        "{title} ya no hace falta: el agente ya no tiene este conector, u otro conector cubre el mismo servicio.",
    ),
];
