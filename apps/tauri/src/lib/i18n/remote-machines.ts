// Machines over SSH: Settings › Devices › Machines and "Runs on" under the composer.
import type { Table } from "./catalog";

export const table: Table = {
  "A port is a number from 1 to 65535.": {
    de: "Ein Port ist eine Zahl von 1 bis 65535.",
    fr: "Un port est un nombre de 1 à 65535.",
    es: "Un puerto es un número del 1 al 65535.",
  },
  "Add a machine": {
    de: "Rechner hinzufügen",
    fr: "Ajouter une machine",
    es: "Añadir una máquina",
  },
  "Add a machine…": {
    de: "Rechner hinzufügen…",
    fr: "Ajouter une machine…",
    es: "Añadir una máquina…",
  },
  "An agent can work on another computer: Nook starts it there over SSH, in a folder on that machine, with the agent's own login there. Pick the machine under the box of a new session.": {
    de: "Ein Agent kann auf einem anderen Computer arbeiten: Nook startet ihn dort über SSH, in einem Ordner auf diesem Rechner, mit der eigenen Anmeldung des Agents dort. Wähle den Rechner unter dem Eingabefeld einer neuen Sitzung.",
    fr: "Un agent peut travailler sur un autre ordinateur : Nook l’y lance via SSH, dans un dossier de cette machine, avec la propre connexion de l’agent là-bas. Choisissez la machine sous le champ d’une nouvelle session.",
    es: "Un agente puede trabajar en otro ordenador: Nook lo inicia allí por SSH, en una carpeta de esa máquina, con el propio inicio de sesión del agente allí. Elige la máquina bajo el cuadro de una sesión nueva.",
  },
  "Another computer over SSH": {
    de: "Ein anderer Computer über SSH",
    fr: "Un autre ordinateur via SSH",
    es: "Otro ordenador por SSH",
  },
  "Back to this computer": {
    de: "Zurück zu diesem Computer",
    fr: "Revenir à cet ordinateur",
    es: "Volver a este ordenador",
  },
  "buildbox or me@buildbox.local": {
    de: "buildbox oder ich@buildbox.local",
    fr: "buildbox ou moi@buildbox.local",
    es: "buildbox o yo@buildbox.local",
  },
  "Choose a key file": {
    de: "Schlüsseldatei wählen",
    fr: "Choisir un fichier de clé",
    es: "Elegir un archivo de clave",
  },
  "Computers your agents work on over SSH": {
    de: "Computer, auf denen deine Agents über SSH arbeiten",
    fr: "Les ordinateurs sur lesquels vos agents travaillent via SSH",
    es: "Ordenadores en los que tus agentes trabajan por SSH",
  },
  "Connected, but no agent is on the PATH there yet.": {
    de: "Verbunden, aber dort ist noch kein Agent im PATH.",
    fr: "Connecté, mais aucun agent n’est encore dans le PATH là-bas.",
    es: "Conectado, pero allí aún no hay ningún agente en el PATH.",
  },
  "Connected. Agents there: {agents}": {
    de: "Verbunden. Agents dort: {agents}",
    fr: "Connecté. Agents là-bas : {agents}",
    es: "Conectado. Agentes allí: {agents}",
  },
  "Connecting…": {
    de: "Verbinden…",
    fr: "Connexion…",
    es: "Conectando…",
  },
  "Folder on {machine}:": {
    de: "Ordner auf {machine}:",
    fr: "Dossier sur {machine} :",
    es: "Carpeta en {machine}:",
  },
  "In a folder or worktree here.": {
    de: "In einem Ordner oder Worktree hier.",
    fr: "Dans un dossier ou un worktree ici.",
    es: "En una carpeta o un worktree aquí.",
  },
  "Key file": {
    de: "Schlüsseldatei",
    fr: "Fichier de clé",
    es: "Archivo de clave",
  },
  "Last reached {when}": {
    de: "Zuletzt erreicht {when}",
    fr: "Dernière connexion {when}",
    es: "Última conexión {when}",
  },
  "Machines": {
    de: "Rechner",
    fr: "Machines",
    es: "Máquinas",
  },
  "No machine yet. Add one with an ssh alias or user@host.": {
    de: "Noch kein Rechner. Füge einen mit einem ssh-Alias oder benutzer@host hinzu.",
    fr: "Aucune machine pour l’instant. Ajoutez-en une avec un alias ssh ou utilisateur@hôte.",
    es: "Aún no hay ninguna máquina. Añade una con un alias de ssh o usuario@host.",
  },
  "Nook logs in with a key (from your ssh agent, your ssh config or the key file). Logging in with a password is not available here yet. Connect once yourself with ssh in a terminal first, so ssh knows the machine.": {
    de: "Nook meldet sich mit einem Schlüssel an (aus deinem ssh-Agent, deiner ssh-Konfiguration oder der Schlüsseldatei). Die Anmeldung mit Passwort ist hier noch nicht möglich. Verbinde dich zuerst einmal selbst mit ssh in einem Terminal, damit ssh den Rechner kennt.",
    fr: "Nook se connecte avec une clé (de votre agent ssh, de votre configuration ssh ou du fichier de clé). La connexion par mot de passe n’est pas encore disponible ici. Connectez-vous d’abord une fois vous-même avec ssh dans un terminal, pour que ssh connaisse la machine.",
    es: "Nook inicia sesión con una clave (de tu agente ssh, tu configuración de ssh o el archivo de clave). Iniciar sesión con contraseña aún no está disponible aquí. Conéctate primero una vez tú mismo con ssh en una terminal, para que ssh conozca la máquina.",
  },
  "Nook on your phone, and the machines your agents work on": {
    de: "Nook auf deinem Telefon und die Rechner, auf denen deine Agents arbeiten",
    fr: "Nook sur votre téléphone, et les machines sur lesquelles vos agents travaillent",
    es: "Nook en tu teléfono, y las máquinas en las que trabajan tus agentes",
  },
  "Port": {
    de: "Port",
    fr: "Port",
    es: "Puerto",
  },
  "Remove machine": {
    de: "Rechner entfernen",
    fr: "Supprimer la machine",
    es: "Quitar la máquina",
  },
  "Runs on": {
    de: "Läuft auf",
    fr: "S’exécute sur",
    es: "Se ejecuta en",
  },
  "Sessions already running there stay as they are. Your keys and your ssh config stay as they are.": {
    de: "Sitzungen, die dort schon laufen, bleiben, wie sie sind. Deine Schlüssel und deine ssh-Konfiguration bleiben erhalten.",
    fr: "Les sessions qui y tournent déjà restent telles quelles. Vos clés et votre configuration ssh restent en place.",
    es: "Las sesiones que ya se ejecutan allí siguen como están. Tus claves y tu configuración de ssh se quedan como están.",
  },
  "The agent uses its own login on {machine}. It must be installed there, and ssh must get in with a key.": {
    de: "Der Agent nutzt seine eigene Anmeldung auf {machine}. Er muss dort installiert sein, und ssh muss mit einem Schlüssel hineinkommen.",
    fr: "L’agent utilise sa propre connexion sur {machine}. Il doit y être installé, et ssh doit pouvoir s’y connecter avec une clé.",
    es: "El agente usa su propio inicio de sesión en {machine}. Debe estar instalado allí, y ssh debe poder entrar con una clave.",
  },
  "Type the folder on {machine}: from / or ~/.": {
    de: "Gib den Ordner auf {machine} ein: ab / oder ~/.",
    fr: "Saisissez le dossier sur {machine} : depuis / ou ~/.",
    es: "Escribe la carpeta en {machine}: desde / o ~/.",
  },
  "via SSH · {host}": {
    de: "über SSH · {host}",
    fr: "via SSH · {host}",
    es: "por SSH · {host}",
  },
  "Where the agent runs": {
    de: "Wo der Agent läuft",
    fr: "Où l’agent s’exécute",
    es: "Dónde se ejecuta el agente",
  },
  "Your ssh config and agent": {
    de: "Deine ssh-Konfiguration und dein Agent",
    fr: "Votre configuration ssh et votre agent",
    es: "Tu configuración de ssh y tu agente",
  },
};
