//! UI control, takeover tools, and Windows UI Automation driver (`ui_control`).

use super::Row;

pub const ROWS: &[Row] = &[
    (
        "Nook cannot control this screen (secure desktop or lock screen).",
        "Nook kann diesen Bildschirm nicht steuern (sicherer Desktop oder Sperrbildschirm).",
        "Nook ne peut pas contrôler cet écran (bureau sécurisé ou écran de verrouillage).",
        "Nook no puede controlar esta pantalla (escritorio seguro o pantalla de bloqueo).",
    ),
    (
        "Nook does not control {app}: it holds passwords, runs commands or is Nook itself.",
        "Nook steuert {app} nicht: Die App enthält Passwörter, führt Befehle aus oder ist Nook selbst.",
        "Nook ne contrôle pas {app} : cette application contient des mots de passe, exécute des commandes ou est Nook lui-même.",
        "Nook no controla {app}: contiene contraseñas, ejecuta comandos o es el propio Nook.",
    ),
    (
        "Windows does not allow Nook to control this app because it runs as administrator.",
        "Windows erlaubt Nook nicht, diese App zu steuern, weil sie als Administrator läuft.",
        "Windows n’autorise pas Nook à contrôler cette application car elle s’exécute en tant qu’administrateur.",
        "Windows no permite que Nook controle esta aplicación porque se ejecuta como administrador.",
    ),
    (
        "No visible window found for this app.",
        "Kein sichtbares Fenster für diese App gefunden.",
        "Aucune fenêtre visible trouvée pour cette application.",
        "No se encontró ninguna ventana visible para esta aplicación.",
    ),
    (
        "Windows blocked the mouse or keyboard input (an administrator app may have focus).",
        "Windows hat die Maus- oder Tastatureingabe blockiert (möglicherweise hat eine Administrator-App den Fokus).",
        "Windows a bloqué la saisie souris ou clavier (une application administrateur a peut-être le focus).",
        "Windows bloqueó la entrada de ratón o teclado (puede que una aplicación de administrador tenga el foco).",
    ),
    (
        "That point no longer belongs to the app's window; read the window again.",
        "Dieser Punkt gehört nicht mehr zum Fenster der App; lies das Fenster erneut.",
        "Ce point n’appartient plus à la fenêtre de l’application ; lisez à nouveau la fenêtre.",
        "Ese punto ya no pertenece a la ventana de la aplicación; vuelve a leer la ventana.",
    ),
    (
        "The app could not be brought to the front.",
        "Die App konnte nicht in den Vordergrund geholt werden.",
        "Impossible de mettre l’application au premier plan.",
        "No se pudo traer la aplicación al frente.",
    ),
    (
        "“{label}” is disabled.",
        "„{label}“ ist deaktiviert.",
        "« {label} » est désactivé.",
        "«{label}» está desactivado.",
    ),
    (
        "Nook never types card or social security numbers.",
        "Nook tippt niemals Karten- oder Sozialversicherungsnummern ein.",
        "Nook ne saisit jamais de numéros de carte ou de sécurité sociale.",
        "Nook nunca escribe números de tarjeta ni de la seguridad social.",
    ),
    (
        "Nook never types into password fields.",
        "Nook tippt niemals in Passwortfelder.",
        "Nook ne saisit jamais dans les champs de mot de passe.",
        "Nook nunca escribe en campos de contraseña.",
    ),
    (
        "Wait for the user",
        "Auf den Nutzer warten",
        "Attendre l’utilisateur",
        "Esperar al usuario",
    ),
    (
        "Describe what the user needs to do.",
        "Beschreibe, was der Nutzer tun muss.",
        "Décrivez ce que l’utilisateur doit faire.",
        "Describe qué debe hacer el usuario.",
    ),
    (
        "Waiting for user: {request}",
        "Warte auf den Nutzer: {request}",
        "En attente de l’utilisateur : {request}",
        "Esperando al usuario: {request}",
    ),
    (
        "No active app found to read.",
        "Keine aktive App zum Lesen gefunden.",
        "Aucune application active trouvée à lire.",
        "No se encontró ninguna aplicación activa para leer.",
    ),
    (
        "{app} is not running right now.",
        "{app} läuft gerade nicht.",
        "{app} n’est pas en cours d’exécution pour le moment.",
        "{app} no se está ejecutando en este momento.",
    ),
    (
        "{app} did not start.",
        "{app} wurde nicht gestartet.",
        "{app} n’a pas démarré.",
        "{app} no se inició.",
    ),
];
