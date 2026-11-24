//! The Agents wave of Windows parity: sessions without a project, `/clear`, deny with a reason, export.

use super::Row;

pub const ROWS: &[Row] = &[
    (
        "Nook could not make a folder for it: {error}",
        "Nook konnte keinen Ordner dafür anlegen: {error}",
        "Nook n’a pas pu créer de dossier pour elle : {error}",
        "Nook no pudo crear una carpeta para ella: {error}",
    ),
    (
        "This folder isn't a folder without a project.",
        "Dieser Ordner ist kein Ordner ohne Projekt.",
        "Ce dossier n’est pas un dossier sans projet.",
        "Esta carpeta no es una carpeta sin proyecto.",
    ),
    ("New conversation", "Neues Gespräch", "Nouvelle conversation", "Nueva conversación"),
    (
        "/clear waits until the agent has stopped.",
        "/clear wartet, bis der Agent angehalten hat.",
        "/clear attend que l’agent se soit arrêté.",
        "/clear espera a que el agente se haya detenido.",
    ),
    ("Only a Markdown file (.md).", "Nur eine Markdown-Datei (.md).", "Uniquement un fichier Markdown (.md).", "Solo un archivo Markdown (.md)."),
    (
        "There is no Antigravity server for this computer.",
        "Für diesen Computer gibt es keinen Antigravity-Server.",
        "Il n'existe pas de serveur Antigravity pour cet ordinateur.",
        "No hay servidor de Antigravity para este ordenador.",
    ),
    (
        "The download does not match (size or SHA-256). Nothing was installed.",
        "Der Download stimmt nicht (Größe oder SHA-256). Es wurde nichts installiert.",
        "Le téléchargement ne correspond pas (taille ou SHA-256). Rien n'a été installé.",
        "La descarga no coincide (tamaño o SHA-256). No se instaló nada.",
    ),
    (
        "The archive does not hold exactly the expected files. Nothing was installed.",
        "Das Archiv enthält nicht genau die erwarteten Dateien. Es wurde nichts installiert.",
        "L'archive ne contient pas exactement les fichiers attendus. Rien n'a été installé.",
        "El archivo no contiene exactamente los archivos esperados. No se instaló nada.",
    ),
    (
        "The test start did not answer as Antigravity. Nothing was installed.",
        "Der Probestart antwortete nicht wie Antigravity. Es wurde nichts installiert.",
        "Le démarrage de test n'a pas répondu comme Antigravity. Rien n'a été installé.",
        "El arranque de prueba no respondió como Antigravity. No se instaló nada.",
    ),
    (
        "Couldn't install Antigravity: {error}",
        "Antigravity konnte nicht installiert werden: {error}",
        "Impossible d'installer Antigravity : {error}",
        "No se pudo instalar Antigravity: {error}",
    ),
    ("The download failed: {error}", "Der Download ist fehlgeschlagen: {error}", "Le téléchargement a échoué : {error}", "La descarga falló: {error}"),
    (
        "Antigravity is still being installed.",
        "Antigravity wird noch installiert.",
        "Antigravity est encore en cours d'installation.",
        "Antigravity aún se está instalando.",
    ),
    ("This picture is too large.", "Dieses Bild ist zu groß.", "Cette image est trop grande.", "Esta imagen es demasiado grande."),
    ("this project", "dieses Projekt", "ce projet", "este proyecto"),
    ("everyone on this project", "alle in diesem Projekt", "toute l'équipe du projet", "todos en este proyecto"),
    ("all your projects", "alle deine Projekte", "tous vos projets", "todos tus proyectos"),
    ("this session", "diese Sitzung", "cette session", "esta sesión"),
    ("as the agent remembers it", "so, wie der Agent es sich merkt", "comme l'agent s'en souvient", "como lo recuerda el agente"),
    ("Always allows {what}", "Erlaubt immer: {what}", "Autorise toujours : {what}", "Permite siempre: {what}"),
];
