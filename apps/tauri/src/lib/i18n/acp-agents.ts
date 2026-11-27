// German, French, and Spanish translations for Settings › Coding agents › ACP agents (AG-21),
// ported from apps/macos/Core/I18n+AgentWork.swift, I18n+ConnectionsAgents.swift,
// I18n+SettingsLayout.swift, I18n+SettingsPages.swift, and I18n+SettingsFlowsA.swift.
import type { Table } from "./catalog";

export const table: Table = {
  "ACP agent": {
    de: "ACP-Agent",
    fr: "Agent ACP",
    es: "Agente ACP",
  },
  "ACP agents": {
    de: "ACP-Agents",
    fr: "Agents ACP",
    es: "Agentes ACP",
  },
  "Agents you add yourself": {
    de: "Agents, die du selbst hinzufügst",
    fr: "Agents que vous ajoutez vous-même",
    es: "Agentes que añades tú",
  },
  "Other agents (ACP)": {
    de: "Andere Agenten (ACP)",
    fr: "Autres agents (ACP)",
    es: "Otros agentes (ACP)",
  },
  "Add ACP agent": {
    de: "ACP-Agent hinzufügen",
    fr: "Ajouter un agent ACP",
    es: "Añadir agente ACP",
  },
  "From the ACP registry…": {
    de: "Aus dem ACP-Verzeichnis…",
    fr: "Depuis le registre ACP…",
    es: "Del registro ACP…",
  },
  "Enter manually…": {
    de: "Selbst eingeben…",
    fr: "Saisir manuellement…",
    es: "Introducir a mano…",
  },
  "Starts through your login shell, so npx, uvx, nvm and asdf work as in Terminal. It signs in during its first session.": {
    de: "Startet über deine Login-Shell, daher funktionieren npx, uvx, nvm und asdf wie im Terminal. Die Anmeldung folgt in der ersten Sitzung.",
    fr: "Démarre via votre shell de connexion : npx, uvx, nvm et asdf marchent comme dans Terminal. La connexion se fait à la première session.",
    es: "Arranca con tu shell de inicio, así que npx, uvx, nvm y asdf funcionan como en Terminal. Inicia sesión en su primera sesión.",
  },
  "No ACP agents yet": {
    de: "Noch keine ACP-Agenten",
    fr: "Aucun agent ACP pour l'instant",
    es: "Aún no hay agentes ACP",
  },
  "Any agent that speaks ACP can be added: pick one from the registry or enter its command.": {
    de: "Jeder Agent, der ACP spricht, kann hinzu: wähle einen aus dem Verzeichnis oder gib seinen Befehl ein.",
    fr: "Tout agent qui parle ACP peut être ajouté : choisissez-en un dans le registre ou saisissez sa commande.",
    es: "Cualquier agente que hable ACP puede añadirse: elige uno del registro o escribe su comando.",
  },
  "Added": {
    de: "Hinzugefügt",
    fr: "Ajouté",
    es: "Añadido",
  },
  "Remove agent": {
    de: "Agent entfernen",
    fr: "Retirer l'agent",
    es: "Quitar agente",
  },
  "Nook forgets this agent and the account its sessions ran as, and deletes a copy it downloaded for it.": {
    de: "Nook vergisst diesen Agenten und das Konto, mit dem seine Sitzungen liefen, und löscht eine Kopie, die es dafür geladen hat.",
    fr: "Nook oublie cet agent et le compte de ses sessions, et supprime la copie qu'il a téléchargée pour lui.",
    es: "Nook olvida este agente y la cuenta con la que corrían sus sesiones, y borra la copia que descargó para él.",
  },
  "Installed in": {
    de: "Installiert in",
    fr: "Installé dans",
    es: "Instalado en",
  },
  "ACP registry": {
    de: "ACP-Verzeichnis",
    fr: "Registre ACP",
    es: "Registro ACP",
  },
  "Agents that speak ACP, from agentclientprotocol.com.": {
    de: "Agenten, die ACP sprechen, von agentclientprotocol.com.",
    fr: "Agents qui parlent ACP, depuis agentclientprotocol.com.",
    es: "Agentes que hablan ACP, de agentclientprotocol.com.",
  },
  "Pick an agent": {
    de: "Wähle einen Agenten",
    fr: "Choisissez un agent",
    es: "Elige un agente",
  },
  "Find an agent": {
    de: "Agenten suchen",
    fr: "Chercher un agent",
    es: "Busca un agente",
  },
  "The registry returned no agents.": {
    de: "Das Verzeichnis lieferte keine Agenten.",
    fr: "Le registre n'a renvoyé aucun agent.",
    es: "El registro no devolvió agentes.",
  },
  "Could not load the registry: {error}": {
    de: "Das Verzeichnis konnte nicht geladen werden: {error}",
    fr: "Impossible de charger le registre : {error}",
    es: "No se pudo cargar el registro: {error}",
  },
  "download": {
    de: "Download",
    fr: "téléchargement",
    es: "descarga",
  },
  "not for this computer": {
    de: "nicht für diesen Computer",
    fr: "pas pour cet ordinateur",
    es: "no para este equipo",
  },
  "Check what runs": {
    de: "Prüfe, was läuft",
    fr: "Vérifiez ce qui s'exécute",
    es: "Comprueba qué se ejecuta",
  },
  "Pick an agent to see the command Nook will run, or the file it will download.": {
    de: "Wähle einen Agenten, um den Befehl zu sehen, den Nook ausführt, oder die Datei, die es lädt.",
    fr: "Choisissez un agent pour voir la commande que Nook exécutera, ou le fichier qu'il téléchargera.",
    es: "Elige un agente para ver el comando que Nook ejecutará o el archivo que descargará.",
  },
  "Runs: {command}": {
    de: "Startet: {command}",
    fr: "Lance : {command}",
    es: "Ejecuta: {command}",
  },
  "Downloads {url} (SHA-256 {hash})": {
    de: "Lädt {url} herunter (SHA-256 {hash})",
    fr: "Télécharge {url} (SHA-256 {hash})",
    es: "Descarga {url} (SHA-256 {hash})",
  },
  "Downloading and checking…": {
    de: "Wird heruntergeladen und geprüft…",
    fr: "Téléchargement et vérification…",
    es: "Descargando y comprobando…",
  },
  "Add an ACP agent": {
    de: "Einen ACP-Agenten hinzufügen",
    fr: "Ajouter un agent ACP",
    es: "Añadir un agente ACP",
  },
  "A name and the command that starts its ACP server.": {
    de: "Ein Name und der Befehl, der seinen ACP-Server startet.",
    fr: "Un nom et la commande qui lance son serveur ACP.",
    es: "Un nombre y el comando que inicia su servidor ACP.",
  },
  "My agent": {
    de: "Mein Agent",
    fr: "Mon agent",
    es: "Mi agente",
  },
  "A quote is left open.": {
    de: "Ein Anführungszeichen ist nicht geschlossen.",
    fr: "Un guillemet n'est pas fermé.",
    es: "Hay una comilla sin cerrar.",
  },
  "Check the command": {
    de: "Befehl prüfen",
    fr: "Vérifier la commande",
    es: "Comprobar el comando",
  },
  "Nook looks for the program the way a session starts it, through your login shell.": {
    de: "Nook sucht das Programm so, wie eine Sitzung es startet: über deine Login-Shell.",
    fr: "Nook cherche le programme comme une session le lance, via votre shell de connexion.",
    es: "Nook busca el programa como lo inicia una sesión, a través de tu shell de inicio de sesión.",
  },
  "Found at {path}.": {
    de: "Gefunden unter {path}.",
    fr: "Trouvé dans {path}.",
    es: "Encontrado en {path}.",
  },
  "Nook could not find {program} on this computer. Install it first, or add it anyway if it is only on the path of your sessions.": {
    de: "Nook konnte {program} auf diesem Computer nicht finden. Installiere es zuerst, oder füge es trotzdem hinzu, wenn es nur im Pfad deiner Sitzungen liegt.",
    fr: "Nook n’a pas trouvé {program} sur cet ordinateur. Installez-le d’abord, ou ajoutez-le quand même s’il n’est que dans le chemin de vos sessions.",
    es: "Nook no encontró {program} en este equipo. Instálalo primero, o añádelo de todos modos si solo está en la ruta de tus sesiones.",
  },
};
