//! Codex app-server, the ACP agents and Antigravity in workspace sessions (`workspace::driver`, `acp`,
//! `codex_app_server`, `antigravity`).

use super::Row;

pub const ROWS: &[Row] = &[
    (
        "This Codex has no usable app-server; Nook uses codex exec.",
        "Dieses Codex hat keinen nutzbaren App-Server; Nook verwendet codex exec.",
        "Ce Codex n'a pas d'app-server utilisable ; Nook utilise codex exec.",
        "Este Codex no tiene un app-server utilizable; Nook usa codex exec.",
    ),
    (
        "{agent} cannot load an earlier conversation; this becomes a new one.",
        "{agent} kann ein früheres Gespräch nicht laden; dies wird ein neues.",
        "{agent} ne peut pas charger une conversation précédente ; celle-ci devient une nouvelle conversation.",
        "{agent} no puede cargar una conversación anterior; esta será una nueva.",
    ),
    (
        "The agent opened no session.",
        "Der Agent hat keine Sitzung geöffnet.",
        "L'agent n'a ouvert aucune session.",
        "El agente no abrió ninguna sesión.",
    ),
    (
        "Antigravity stopped without replying; Nook asks it to carry on.",
        "Antigravity hat ohne Antwort aufgehört; Nook bittet es weiterzumachen.",
        "Antigravity s'est arrêté sans répondre ; Nook lui demande de continuer.",
        "Antigravity se detuvo sin responder; Nook le pide que continúe.",
    ),
    (
        "The agent refused this request.",
        "Der Agent hat diese Anfrage abgelehnt.",
        "L'agent a refusé cette demande.",
        "El agente rechazó esta solicitud.",
    ),
    (
        "Antigravity asks you to sign in: Google's sign-in page opened in your browser.",
        "Antigravity bittet dich, dich anzumelden: Googles Anmeldeseite wurde im Browser geöffnet.",
        "Antigravity vous demande de vous connecter : la page de connexion Google s'est ouverte dans votre navigateur.",
        "Antigravity te pide iniciar sesión: la página de inicio de sesión de Google se abrió en tu navegador.",
    ),
    (
        "Antigravity's ACP server isn't on this computer. Put agy_acp_server (with localharness_external beside it) in {folder} or on your PATH.",
        "Der ACP-Server von Antigravity ist nicht auf diesem Computer. Lege agy_acp_server (mit localharness_external daneben) in {folder} oder in deinen PATH.",
        "Le serveur ACP d'Antigravity n'est pas sur cet ordinateur. Placez agy_acp_server (avec localharness_external à côté) dans {folder} ou dans votre PATH.",
        "El servidor ACP de Antigravity no está en este ordenador. Pon agy_acp_server (con localharness_external al lado) en {folder} o en tu PATH.",
    ),
    (
        "Couldn't prepare Antigravity: {error}",
        "Antigravity konnte nicht vorbereitet werden: {error}",
        "Impossible de préparer Antigravity : {error}",
        "No se pudo preparar Antigravity: {error}",
    ),
    (
        "Codex started no thread.",
        "Codex hat kein Gespräch gestartet.",
        "Codex n'a démarré aucune conversation.",
        "Codex no inició ninguna conversación.",
    ),
    ("Apply file changes", "Dateiänderungen anwenden", "Appliquer les modifications de fichiers", "Aplicar cambios en archivos"),
    (
        "This OpenCode has no server Nook can use (OpenCode 2.0.18 or newer); Nook uses ACP.",
        "Dieses OpenCode hat keinen Server, den Nook nutzen kann (OpenCode 2.0.18 oder neuer); Nook verwendet ACP.",
        "Cet OpenCode n'a pas de serveur utilisable par Nook (OpenCode 2.0.18 ou plus récent) ; Nook utilise ACP.",
        "Este OpenCode no tiene un servidor que Nook pueda usar (OpenCode 2.0.18 o posterior); Nook usa ACP.",
    ),
    (
        "OpenCode's server did not start ({error}); Nook uses ACP.",
        "Der Server von OpenCode ist nicht gestartet ({error}); Nook verwendet ACP.",
        "Le serveur d'OpenCode n'a pas démarré ({error}) ; Nook utilise ACP.",
        "El servidor de OpenCode no se inició ({error}); Nook usa ACP.",
    ),
    (
        "{agent} could not switch to {model}.",
        "{agent} konnte nicht zu {model} wechseln.",
        "{agent} n'a pas pu passer à {model}.",
        "{agent} no pudo cambiar a {model}.",
    ),
    ("Stopping…", "Wird gestoppt…", "Arrêt…", "Deteniendo…"),
    ("Denied: {reason}", "Abgelehnt: {reason}", "Refusé : {reason}", "Rechazado: {reason}"),
    (
        "Your answer did not reach OpenCode: {error}",
        "Deine Antwort hat OpenCode nicht erreicht: {error}",
        "Votre réponse n'est pas parvenue à OpenCode : {error}",
        "Tu respuesta no llegó a OpenCode: {error}",
    ),
    (
        "OpenCode asked a question Nook cannot show yet; it was skipped.",
        "OpenCode hat eine Frage gestellt, die Nook noch nicht anzeigen kann; sie wurde übersprungen.",
        "OpenCode a posé une question que Nook ne sait pas encore afficher ; elle a été ignorée.",
        "OpenCode hizo una pregunta que Nook aún no puede mostrar; se omitió.",
    ),
    ("Retrying…", "Wird erneut versucht…", "Nouvelle tentative…", "Reintentando…"),
    (
        "The session resumed in the background.",
        "Die Sitzung wurde im Hintergrund fortgesetzt.",
        "La session a repris en arrière-plan.",
        "La sesión continuó en segundo plano.",
    ),
    (
        "{agent} stopped without replying.",
        "{agent} hat ohne Antwort gestoppt.",
        "{agent} s'est arrêté sans répondre.",
        "{agent} se detuvo sin responder.",
    ),
    (
        "The connection to OpenCode dropped for a moment; the turn failed.",
        "Die Verbindung zu OpenCode war kurz unterbrochen; der Durchgang ist fehlgeschlagen.",
        "La connexion à OpenCode a été coupée un instant ; le tour a échoué.",
        "La conexión con OpenCode se cortó un momento; el turno falló.",
    ),
    (
        "The OpenCode server stopped.",
        "Der OpenCode-Server wurde gestoppt.",
        "Le serveur OpenCode s'est arrêté.",
        "El servidor de OpenCode se detuvo.",
    ),
];
