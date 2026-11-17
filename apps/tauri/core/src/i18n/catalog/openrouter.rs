//! Signing in to OpenRouter (`connectors::openrouter`).

use super::Row;

pub const ROWS: &[Row] = &[
    (
        "The browser did not open: {error}",
        "Der Browser ging nicht auf: {error}",
        "Le navigateur ne s’est pas ouvert : {error}",
        "El navegador no se abrió: {error}",
    ),
    (
        "Signing in to OpenRouter stopped.",
        "Die Anmeldung bei OpenRouter wurde beendet.",
        "La connexion à OpenRouter s’est arrêtée.",
        "El inicio de sesión en OpenRouter se detuvo.",
    ),
    (
        "OpenRouter did not give Nook access.",
        "OpenRouter hat Nook keinen Zugriff gegeben.",
        "OpenRouter n’a pas donné accès à Nook.",
        "OpenRouter no dio acceso a Nook.",
    ),
    (
        "OpenRouter gave no key. Try again.",
        "OpenRouter hat keinen Schlüssel gegeben. Versuche es erneut.",
        "OpenRouter n’a pas donné de clé. Réessayez.",
        "OpenRouter no dio ninguna clave. Inténtalo de nuevo.",
    ),
];
