//! Updates for a downloaded Nook on Windows and Linux (`src-tauri/src/updates.rs`).

use super::Row;

pub const ROWS: &[Row] = &[
    (
        "Nook restarted, but version {version} was not installed. Try again or download it from the releases page.",
        "Nook wurde neu gestartet, aber Version {version} wurde nicht installiert. Versuch es noch einmal oder lade sie von der Release-Seite herunter.",
        "Nook a redémarré, mais la version {version} n’a pas été installée. Réessaie ou télécharge-la depuis la page des versions.",
        "Nook se reinició, pero la versión {version} no se instaló. Vuelve a intentarlo o descárgala desde la página de versiones.",
    ),
    (
        "This version was not built by the release workflow and does not update itself.",
        "Diese Version wurde nicht vom Release-Workflow gebaut und aktualisiert sich nicht selbst.",
        "Cette version n’a pas été construite par le workflow de publication et ne se met pas à jour toute seule.",
        "Esta versión no la creó el flujo de publicación y no se actualiza sola.",
    ),
    (
        "Installed with an .msi or .deb: Nook does not update that package itself. Install the setup (Windows) or the AppImage (Linux) once, and Nook updates itself from then on.",
        "Mit einer .msi oder .deb installiert: Dieses Paket aktualisiert Nook nicht selbst. Installiere einmal das Setup (Windows) oder das AppImage (Linux), dann aktualisiert sich Nook ab dann selbst.",
        "Installé avec un .msi ou un .deb : Nook ne met pas ce paquet à jour lui-même. Installe une fois le setup (Windows) ou l’AppImage (Linux), et Nook se mettra ensuite à jour tout seul.",
        "Instalado con un .msi o .deb: Nook no actualiza ese paquete por sí mismo. Instala una vez el instalador (Windows) o la AppImage (Linux) y a partir de entonces Nook se actualiza solo.",
    ),
    (
        "Nook does not update itself on this platform yet.",
        "Auf dieser Plattform aktualisiert sich Nook noch nicht selbst.",
        "Nook ne se met pas encore à jour tout seul sur cette plateforme.",
        "Nook todavía no se actualiza solo en esta plataforma.",
    ),
    ("GitHub answered with {status}.", "GitHub antwortete mit {status}.", "GitHub a répondu {status}.", "GitHub respondió con {status}."),
    ("The download returned {status}.", "Der Download lieferte {status}.", "Le téléchargement a renvoyé {status}.", "La descarga devolvió {status}."),
    (
        "The download is larger than expected.",
        "Der Download ist größer als erwartet.",
        "Le téléchargement est plus gros que prévu.",
        "La descarga es más grande de lo esperado.",
    ),
    ("Not a release build.", "Keine Release-Version.", "Pas une version publiée.", "No es una versión publicada."),
    (
        "This version has no key to check updates with.",
        "Diese Version hat keinen Schlüssel, um Updates zu prüfen.",
        "Cette version n’a pas de clé pour vérifier les mises à jour.",
        "Esta versión no tiene una clave para comprobar las actualizaciones.",
    ),
    ("There is no update.", "Es gibt kein Update.", "Il n’y a pas de mise à jour.", "No hay ninguna actualización."),
    (
        "The download's signature does not match. Nook did not install it.",
        "Die Signatur des Downloads stimmt nicht. Nook hat ihn nicht installiert.",
        "La signature du téléchargement ne correspond pas. Nook ne l’a pas installé.",
        "La firma de la descarga no coincide. Nook no la ha instalado.",
    ),
    ("Unexpected file name.", "Unerwarteter Dateiname.", "Nom de fichier inattendu.", "Nombre de archivo inesperado."),
    (
        "This installation does not update itself.",
        "Diese Installation aktualisiert sich nicht selbst.",
        "Cette installation ne se met pas à jour toute seule.",
        "Esta instalación no se actualiza sola.",
    ),
    (
        "Could not start the setup: {error}",
        "Das Setup konnte nicht gestartet werden: {error}",
        "Impossible de lancer le setup : {error}",
        "No se pudo iniciar el instalador: {error}",
    ),
    (
        "The Windows setup only runs on Windows.",
        "Das Windows-Setup läuft nur unter Windows.",
        "Le setup Windows ne fonctionne que sous Windows.",
        "El instalador de Windows solo funciona en Windows.",
    ),
    ("Unknown folder.", "Unbekannter Ordner.", "Dossier inconnu.", "Carpeta desconocida."),
    (
        "Could not replace the AppImage: {error}",
        "Das AppImage konnte nicht ersetzt werden: {error}",
        "Impossible de remplacer l’AppImage : {error}",
        "No se pudo reemplazar la AppImage: {error}",
    ),
    ("Could not restart Nook: {error}", "Nook konnte nicht neu gestartet werden: {error}", "Impossible de redémarrer Nook : {error}", "No se pudo reiniciar Nook: {error}"),

    (
        "{error} Agents and WhatsApp were stopped: restart Nook to carry on.",
        "{error} Agenten und WhatsApp wurden gestoppt: Starte Nook neu, um weiterzumachen.",
        "{error} Les agents et WhatsApp ont été arrêtés : redémarre Nook pour continuer.",
        "{error} Los agentes y WhatsApp se detuvieron: reinicia Nook para continuar.",
    ),
    (
        "Updates are turned off by NOOK_DISABLE_UPDATES.",
        "Updates sind durch NOOK_DISABLE_UPDATES ausgeschaltet.",
        "Les mises à jour sont désactivées par NOOK_DISABLE_UPDATES.",
        "Las actualizaciones están desactivadas por NOOK_DISABLE_UPDATES.",
    ),
    (
        "Updates are off: Nook cannot read your administrator's policy. Ask your administrator for help.",
        "Updates sind aus: Nook kann die Richtlinie deines Administrators nicht lesen. Frag deinen Administrator um Hilfe.",
        "Les mises à jour sont désactivées : Nook ne peut pas lire la stratégie de ton administrateur. Demande de l’aide à ton administrateur.",
        "Las actualizaciones están desactivadas: Nook no puede leer la directiva de tu administrador. Pide ayuda a tu administrador.",
    ),
    (
        "Your administrator turned updates off on this computer.",
        "Dein Administrator hat Updates auf diesem Computer ausgeschaltet.",
        "Ton administrateur a désactivé les mises à jour sur cet ordinateur.",
        "Tu administrador ha desactivado las actualizaciones en este ordenador.",
    ),
    (
        "Nook was installed some other way than the setup, .msi, AppImage or .deb, so it does not update itself. The newest one is on the releases page.",
        "Nook wurde anders als mit Setup, .msi, AppImage oder .deb installiert und aktualisiert sich daher nicht selbst. Die neueste Version findest du auf der Release-Seite.",
        "Nook a été installé autrement qu’avec le setup, le .msi, l’AppImage ou le .deb, il ne se met donc pas à jour tout seul. La version la plus récente est sur la page des versions.",
        "Nook se instaló de otra forma que con el instalador, el .msi, la AppImage o el .deb, así que no se actualiza solo. La más reciente está en la página de versiones.",
    ),
    ("Unexpected answer from GitHub.", "Unerwartete Antwort von GitHub.", "Réponse inattendue de GitHub.", "Respuesta inesperada de GitHub."),
    (
        "Could not start the installation: {error}",
        "Die Installation konnte nicht gestartet werden: {error}",
        "Impossible de lancer l’installation : {error}",
        "No se pudo iniciar la instalación: {error}",
    ),
    (
        "The installation was cancelled: without your password Nook cannot update the package.",
        "Die Installation wurde abgebrochen: Ohne dein Passwort kann Nook das Paket nicht aktualisieren.",
        "L’installation a été annulée : sans ton mot de passe, Nook ne peut pas mettre à jour le paquet.",
        "La instalación se canceló: sin tu contraseña Nook no puede actualizar el paquete.",
    ),
    (
        "The package could not be installed: {error}",
        "Das Paket konnte nicht installiert werden: {error}",
        "Le paquet n’a pas pu être installé : {error}",
        "No se pudo instalar el paquete: {error}",
    ),
];
