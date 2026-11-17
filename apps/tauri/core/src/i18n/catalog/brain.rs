//! The brain: subscription brains (Codex, Gemini CLI, Grok, Kimi Code, Mistral Vibe) and what they cannot do.

use super::Row;

pub const ROWS: &[Row] = &[
    (
        "{name} is not signed in. Sign in under Settings › Brain and try again.",
        "{name} ist nicht angemeldet. Melde dich unter Einstellungen › Gehirn an und versuche es erneut.",
        "{name} n’est pas connecté. Connectez-vous dans Réglages › Cerveau et réessayez.",
        "{name} no ha iniciado sesión. Inicia sesión en Ajustes › Cerebro e inténtalo de nuevo.",
    ),
    (
        "This version of {name} is too old to run safely as Nook's brain. Update it and try again.",
        "Diese Version von {name} ist zu alt, um sicher als Nooks Gehirn zu laufen. Aktualisiere sie und versuche es erneut.",
        "Cette version de {name} est trop ancienne pour servir de cerveau à Nook en toute sécurité. Mettez-la à jour et réessayez.",
        "Esta versión de {name} es demasiado antigua para funcionar con seguridad como cerebro de Nook. Actualízala e inténtalo de nuevo.",
    ),
    (
        "Your {name} limit has been reached. {detail}",
        "Dein Limit bei {name} ist erreicht. {detail}",
        "Votre limite {name} est atteinte. {detail}",
        "Has alcanzado tu límite de {name}. {detail}",
    ),
    ("{name} did not answer: {detail}", "{name} hat nicht geantwortet: {detail}", "{name} n’a pas répondu : {detail}", "{name} no respondió: {detail}"),
    (
        "{name} is not on this computer. Set it up in Settings › Brain.",
        "{name} ist nicht auf diesem Computer. Richte es unter Einstellungen › Gehirn ein.",
        "{name} n’est pas sur cet ordinateur. Configurez-le dans Réglages › Cerveau.",
        "{name} no está en este ordenador. Configúralo en Ajustes › Cerebro.",
    ),
    (
        "{name} did not answer within two minutes.",
        "{name} hat nicht innerhalb von zwei Minuten geantwortet.",
        "{name} n’a pas répondu en deux minutes.",
        "{name} no respondió en dos minutos.",
    ),
    (
        "{name} does not run on a phone. Choose another brain in Settings › Brain.",
        "{name} läuft nicht auf einem Telefon. Wähle unter Einstellungen › Gehirn ein anderes Gehirn.",
        "{name} ne fonctionne pas sur un téléphone. Choisissez un autre cerveau dans Réglages › Cerveau.",
        "{name} no funciona en un teléfono. Elige otro cerebro en Ajustes › Cerebro.",
    ),
    (
        "{name} as the brain cannot autocomplete. Choose a model on this computer.",
        "{name} kann als Gehirn nicht vervollständigen. Wähle ein Modell auf diesem Computer.",
        "{name} ne peut pas compléter le texte en tant que cerveau. Choisissez un modèle sur cet ordinateur.",
        "{name} como cerebro no puede autocompletar. Elige un modelo en este ordenador.",
    ),
    (
        "{name} as the brain cannot rewrite here (yet).",
        "{name} kann als Gehirn hier (noch) nicht umschreiben.",
        "{name} ne peut pas (encore) réécrire ici en tant que cerveau.",
        "{name} como cerebro no puede reescribir aquí (todavía).",
    ),
    (
        "{name} is not on this computer or not signed in. Set it up in Settings › Brain, or choose another brain.",
        "{name} ist nicht auf diesem Computer oder nicht angemeldet. Richte es unter Einstellungen › Gehirn ein oder wähle ein anderes Gehirn.",
        "{name} n’est pas sur cet ordinateur ou n’est pas connecté. Configurez-le dans Réglages › Cerveau, ou choisissez un autre cerveau.",
        "{name} no está en este ordenador o no ha iniciado sesión. Configúralo en Ajustes › Cerebro o elige otro cerebro.",
    ),
];
