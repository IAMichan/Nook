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
        "The registry is too large.",
        "Das Verzeichnis ist zu groß.",
        "Le registre est trop volumineux.",
        "El registro es demasiado grande.",
    ),
    (
        "This agent has no download for this computer.",
        "Dieser Agent hat keinen Download für diesen Computer.",
        "Cet agent n'a pas de téléchargement pour cet ordinateur.",
        "Este agente no tiene descarga para este ordenador.",
    ),
    (
        "Download failed (HTTP {status}).",
        "Download fehlgeschlagen (HTTP {status}).",
        "Échec du téléchargement (HTTP {status}).",
        "La descarga falló (HTTP {status}).",
    ),
    (
        "The download is empty or larger than 1 GB.",
        "Der Download ist leer oder größer als 1 GB.",
        "Le téléchargement est vide ou dépasse 1 Go.",
        "La descarga está vacía o supera 1 GB.",
    ),
    (
        "The download does not match the registry's checksum: not installed.",
        "Der Download passt nicht zur Prüfsumme des Registers: nicht installiert.",
        "Le téléchargement ne correspond pas à la somme de contrôle du registre : non installé.",
        "La descarga no coincide con la suma de comprobación del registro: no instalado.",
    ),
    (
        "Unpacking failed: {detail}",
        "Entpacken fehlgeschlagen: {detail}",
        "Échec de la décompression : {detail}",
        "Error al descomprimir: {detail}",
    ),
    (
        "The agent's program is not in the download.",
        "Das Programm des Agenten ist nicht im Download.",
        "Le programme de l'agent n'est pas dans le téléchargement.",
        "El programa del agente no está en la descarga.",
    ),
    (
        "This ACP agent is no longer set up (Settings › Coding agents).",
        "Dieser ACP-Agent ist nicht mehr eingerichtet (Einstellungen › Coding-Agenten).",
        "Cet agent ACP n'est plus configuré (Réglages › Agents de code).",
        "Este agente ACP ya no está configurado (Ajustes › Agentes de código).",
    ),
    (
        "Enter a name for this agent.",
        "Gib einen Namen für diesen Agenten ein.",
        "Saisissez un nom pour cet agent.",
        "Escribe un nombre para este agente.",
    ),
    (
        "Enter a valid command (no unclosed quotes).",
        "Gib einen gültigen Befehl ein (keine offenen Anführungszeichen).",
        "Saisissez une commande valide (pas de guillemet non fermé).",
        "Escribe un comando válido (sin comillas sin cerrar).",
    ),
    (
        "This registry entry cannot be started on this computer.",
        "Dieser Registereintrag kann auf diesem Computer nicht gestartet werden.",
        "Cette entrée du registre ne peut pas être lancée sur cet ordinateur.",
        "Esta entrada del registro no puede iniciarse en este ordenador.",
    ),
    (
        "Give the project a name.",
        "Gib dem Projekt einen Namen.",
        "Donnez un nom au projet.",
        "Ponle un nombre al proyecto.",
    ),
    (
        "{name} already exists and is not empty.",
        "{name} existiert bereits und ist nicht leer.",
        "{name} existe déjà et n'est pas vide.",
        "{name} ya existe y no está vacía.",
    ),
];
