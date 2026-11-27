//! Sessions on another machine over SSH (`workspace::remote`, `manager_remote`).

use super::Row;

pub const ROWS: &[Row] = &[
    (
        "A key file starts with / or ~/ (for example ~/.ssh/id_ed25519).",
        "Eine Schlüsseldatei beginnt mit / oder ~/ (zum Beispiel ~/.ssh/id_ed25519).",
        "Un fichier de clé commence par / ou ~/ (par exemple ~/.ssh/id_ed25519).",
        "Un archivo de clave empieza por / o ~/ (por ejemplo ~/.ssh/id_ed25519).",
    ),
    (
        "Could not start ssh: {e}",
        "ssh konnte nicht gestartet werden: {e}",
        "Impossible de lancer ssh : {e}",
        "No se pudo iniciar ssh: {e}",
    ),
    (
        "No key got in. Add your key to your ssh agent, choose a key file, or log in with a password.",
        "Kein Schlüssel kam durch. Füge deinen Schlüssel deinem ssh-Agent hinzu, wähle eine Schlüsseldatei oder melde dich mit einem Passwort an.",
        "Aucune clé n’a été acceptée. Ajoutez votre clé à votre agent ssh, choisissez un fichier de clé ou connectez-vous avec un mot de passe.",
        "Ninguna clave fue aceptada. Añade tu clave a tu agente ssh, elige un archivo de clave o inicia sesión con una contraseña.",
    ),
    (
        "The password is not right.",
        "Das Passwort stimmt nicht.",
        "Le mot de passe n’est pas correct.",
        "La contraseña no es correcta.",
    ),
    (
        "This machine asks for a password. Type it in Settings › Devices › Machines.",
        "Dieser Rechner fragt nach einem Passwort. Gib es unter Einstellungen › Geräte › Rechner ein.",
        "Cette machine demande un mot de passe. Saisissez-le dans Réglages › Appareils › Machines.",
        "Esta máquina pide una contraseña. Escríbela en Ajustes › Dispositivos › Máquinas.",
    ),
    (
        "Type the password for {machine} in Settings › Devices › Machines first.",
        "Gib zuerst das Passwort für {machine} unter Einstellungen › Geräte › Rechner ein.",
        "Saisissez d’abord le mot de passe de {machine} dans Réglages › Appareils › Machines.",
        "Escribe primero la contraseña de {machine} en Ajustes › Dispositivos › Máquinas.",
    ),
    (
        "Runs on {name} ({host}) in {folder}",
        "Läuft auf {name} ({host}) in {folder}",
        "S’exécute sur {name} ({host}) dans {folder}",
        "Se ejecuta en {name} ({host}) en {folder}",
    ),
    (
        "ssh does not know this machine yet (or its key changed). Connect once yourself with ssh in a terminal and try again.",
        "ssh kennt diesen Rechner noch nicht (oder sein Schlüssel hat sich geändert). Verbinde dich einmal selbst mit ssh in einem Terminal und versuche es erneut.",
        "ssh ne connaît pas encore cette machine (ou sa clé a changé). Connectez-vous une fois vous-même avec ssh dans un terminal, puis réessayez.",
        "ssh aún no conoce esta máquina (o su clave cambió). Conéctate una vez tú mismo con ssh en una terminal y vuelve a intentarlo.",
    ),
    (
        "That is not an address for ssh. Type an alias from your ssh config or user@host.",
        "Das ist keine Adresse für ssh. Gib einen Alias aus deiner ssh-Konfiguration oder benutzer@host ein.",
        "Ce n’est pas une adresse pour ssh. Saisissez un alias de votre configuration ssh ou utilisateur@hôte.",
        "Esa no es una dirección para ssh. Escribe un alias de tu configuración de ssh o usuario@host.",
    ),
    (
        "The home folder on the other machine cannot be found, so no worktree can be made there.",
        "Der Benutzerordner auf dem anderen Rechner ist nicht zu finden, daher kann dort kein Worktree entstehen.",
        "Le dossier personnel de l’autre machine est introuvable : impossible d’y créer un worktree.",
        "No se encuentra la carpeta personal en la otra máquina, así que no se puede crear allí un worktree.",
    ),
    (
        "The machine could not be reached. Check that it is on and that the address is right.",
        "Der Rechner war nicht erreichbar. Prüfe, ob er eingeschaltet ist und die Adresse stimmt.",
        "La machine est injoignable. Vérifiez qu’elle est allumée et que l’adresse est correcte.",
        "No se pudo contactar con la máquina. Comprueba que está encendida y que la dirección es correcta.",
    ),
    (
        "The machine did not answer in time. Check that it is on and that the address is right.",
        "Der Rechner hat nicht rechtzeitig geantwortet. Prüfe, ob er eingeschaltet ist und die Adresse stimmt.",
        "La machine n’a pas répondu à temps. Vérifiez qu’elle est allumée et que l’adresse est correcte.",
        "La máquina no respondió a tiempo. Comprueba que está encendida y que la dirección es correcta.",
    ),
    (
        "This machine is no longer in Nook. Choose another one.",
        "Dieser Rechner ist nicht mehr in Nook. Wähle einen anderen.",
        "Cette machine n’est plus dans Nook. Choisissez-en une autre.",
        "Esta máquina ya no está en Nook. Elige otra.",
    ),
    (
        "Type the folder on the machine: from / or from your home folder (~/code/app).",
        "Gib den Ordner auf dem Rechner ein: ab / oder ab deinem Benutzerordner (~/code/app).",
        "Saisissez le dossier sur la machine : depuis / ou depuis votre dossier personnel (~/code/app).",
        "Escribe la carpeta en la máquina: desde / o desde tu carpeta personal (~/code/app).",
    ),
];
