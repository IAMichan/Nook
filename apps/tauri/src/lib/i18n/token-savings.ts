// German, French, and Spanish translations for TokenSettingsSection & token-savings helpers (AG-32),
// ported verbatim from macOS `I18n+SettingsPages.swift`, `I18n+Workspace.swift`, and `I18n+Languages.swift`.
import type { Table } from "./catalog";

export const table: Table = {
  "What Nook does": {
    de: "Was Nook tut",
    fr: "Ce que fait Nook",
    es: "Lo que hace Nook",
  },
  "Summarize long sessions before their cache expires": {
    de: "Lange Sitzungen zusammenfassen, bevor ihr Cache abläuft",
    fr: "Résumer les longues sessions avant l'expiration de leur cache",
    es: "Resumir sesiones largas antes de que caduque su caché",
  },
  "An idle session over 200,000 tokens is summarized (/compact) shortly before the agent's prompt cache expires. Your next message then reads a short summary instead of the whole history again at the full price. Claude Code only for now: the other agents do not report how long their cache lives.": {
    de: "Eine ruhende Sitzung mit mehr als 200.000 Tokens wird kurz vor Ablauf des Prompt-Caches des Agenten zusammengefasst (/compact). Deine nächste Nachricht liest dann eine kurze Zusammenfassung statt des ganzen Verlaufs zum vollen Preis. Vorerst nur Claude Code: die anderen Agenten melden nicht, wie lange ihr Cache lebt.",
    fr: "Une session inactive de plus de 200 000 tokens est résumée (/compact) peu avant l'expiration du cache de prompt de l'agent. Votre prochain message lit alors un court résumé au lieu de tout l'historique au plein tarif. Claude Code seulement pour l'instant : les autres agents n'indiquent pas la durée de vie de leur cache.",
    es: "Una sesión inactiva de más de 200.000 tokens se resume (/compact) poco antes de que caduque la caché de prompts del agente. Tu próximo mensaje lee entonces un resumen breve en lugar de todo el historial a precio completo. Por ahora solo Claude Code: los demás agentes no indican cuánto dura su caché.",
  },
  "Summarize a session once its context passes": {
    de: "Eine Sitzung zusammenfassen, sobald der Kontext größer ist als",
    fr: "Résumer une session dès que son contexte dépasse",
    es: "Resumir una sesión cuando su contexto supere",
  },
  "When a turn ends and the session's context is over this size, the agent summarizes the conversation (/compact). Every message rereads the whole context, so a session that keeps growing costs several times more per message. Works for every agent that has /compact.": {
    de: "Endet ein Durchlauf und der Kontext der Sitzung liegt über dieser Größe, fasst der Agent das Gespräch zusammen (/compact). Jede Nachricht liest den ganzen Kontext erneut, eine weiter wachsende Sitzung kostet also ein Vielfaches pro Nachricht. Gilt für jeden Agenten mit /compact.",
    fr: "Quand un tour se termine et que le contexte de la session dépasse cette taille, l'agent résume la conversation (/compact). Chaque message relit tout le contexte : une session qui grossit coûte plusieurs fois plus par message. Fonctionne pour tout agent doté de /compact.",
    es: "Cuando termina un turno y el contexto de la sesión supera este tamaño, el agente resume la conversación (/compact). Cada mensaje vuelve a leer todo el contexto, así que una sesión que sigue creciendo cuesta varias veces más por mensaje. Funciona con cualquier agente que tenga /compact.",
  },
  "{n}K tokens": {
    de: "{n}K Tokens",
    fr: "{n}K tokens",
    es: "{n}K tokens",
  },
  "In the sessions it starts, Nook turns on Claude Code's tool search (unless you set it yourself) and gives agents its own instructions once. The suggestions below look at your own setup of each agent.": {
    de: "In den Sitzungen, die Nook startet, schaltet es die Tool-Suche von Claude Code ein (außer du hast sie selbst eingestellt) und gibt Agenten seine eigenen Anweisungen nur einmal. Die Vorschläge unten betreffen deine eigene Einrichtung jedes Agenten.",
    fr: "Dans les sessions qu'il lance, Nook active la recherche d'outils de Claude Code (sauf si vous l'avez réglée vous-même) et ne donne ses propres instructions aux agents qu'une fois. Les suggestions ci-dessous portent sur votre propre configuration de chaque agent.",
    es: "En las sesiones que inicia, Nook activa la búsqueda de herramientas de Claude Code (salvo que la hayas configurado tú) y da sus propias instrucciones a los agentes una sola vez. Las sugerencias de abajo miran tu propia configuración de cada agente.",
  },
  "Your agents": {
    de: "Deine Agenten",
    fr: "Vos agents",
    es: "Tus agentes",
  },
  "What goes with every request of an agent without being used, read from its own files (Claude Code also from its transcripts of the last 30 days). Nook changes none of them: copy a setting into your file, or apply it to the sessions Nook starts.": {
    de: "Was bei jeder Anfrage eines Agenten mitgeht, ohne genutzt zu werden, gelesen aus seinen eigenen Dateien (bei Claude Code auch aus den Transkripten der letzten 30 Tage). Nook ändert nichts daran: kopiere eine Einstellung in deine Datei oder wende sie auf die Sitzungen an, die Nook startet.",
    fr: "Ce qui accompagne chaque requête d'un agent sans être utilisé, lu dans ses propres fichiers (pour Claude Code, aussi dans ses transcriptions des 30 derniers jours). Nook n'y change rien : copiez un réglage dans votre fichier, ou appliquez-le aux sessions que Nook lance.",
    es: "Lo que acompaña cada solicitud de un agente sin usarse, leído de sus propios archivos (en Claude Code, también de sus transcripciones de los últimos 30 días). Nook no cambia nada: copia un ajuste en tu archivo o aplícalo a las sesiones que inicia Nook.",
  },
  "Checking your agents…": {
    de: "Deine Agenten werden geprüft…",
    fr: "Vérification de vos agents…",
    es: "Revisando tus agentes…",
  },
  "No suggestions in the files Nook can read.": {
    de: "Keine Vorschläge in den Dateien, die Nook lesen kann.",
    fr: "Aucune suggestion dans les fichiers que Nook peut lire.",
    es: "No hay sugerencias en los archivos que Nook puede leer.",
  },
  "Nook reads Claude Code, Codex, Gemini CLI, OpenCode, Cursor and Antigravity from their files in your home folder; a file it cannot read is skipped. Grok and the ACP agents you added keep no file Nook knows, so they are not checked.": {
    de: "Nook liest Claude Code, Codex, Gemini CLI, OpenCode, Cursor und Antigravity aus ihren Dateien in deinem Benutzerordner; eine Datei, die es nicht lesen kann, wird übersprungen. Grok und die ACP-Agenten, die du hinzugefügt hast, haben keine Datei, die Nook kennt, deshalb werden sie nicht geprüft.",
    fr: "Nook lit Claude Code, Codex, Gemini CLI, OpenCode, Cursor et Antigravity dans leurs fichiers de votre dossier personnel ; un fichier illisible est ignoré. Grok et les agents ACP que vous avez ajoutés n'ont pas de fichier connu de Nook, ils ne sont donc pas vérifiés.",
    es: "Nook lee Claude Code, Codex, Gemini CLI, OpenCode, Cursor y Antigravity desde sus archivos en tu carpeta personal; un archivo que no puede leer se omite. Grok y los agentes ACP que añadiste no tienen un archivo que Nook conozca, así que no se revisan.",
  },
  "Check again": {
    de: "Erneut prüfen",
    fr: "Vérifier à nouveau",
    es: "Revisar de nuevo",
  },
  "Plugins you do not use": {
    de: "Plugins, die du nicht nutzt",
    fr: "Plugins que vous n'utilisez pas",
    es: "Plugins que no usas",
  },
  "claude.ai connectors you do not use": {
    de: "claude.ai-Connectors, die du nicht nutzt",
    fr: "Connecteurs claude.ai que vous n'utilisez pas",
    es: "Conectores de claude.ai que no usas",
  },
  "MCP servers you do not use": {
    de: "MCP-Server, die du nicht nutzt",
    fr: "Serveurs MCP que vous n'utilisez pas",
    es: "Servidores MCP que no usas",
  },
  "MCP servers in every session": {
    de: "MCP-Server in jeder Sitzung",
    fr: "Serveurs MCP dans chaque session",
    es: "Servidores MCP en cada sesión",
  },
  "Long personal instructions": {
    de: "Lange persönliche Anweisungen",
    fr: "Longues instructions personnelles",
    es: "Instrucciones personales largas",
  },
  "Auto-compact is off": {
    de: "Auto-Compact ist aus",
    fr: "L'auto-compact est désactivé",
    es: "El auto-compact está desactivado",
  },
  "Their skills and agents are listed in every request, though none was used in 30 days. Turned off, you can turn a plugin back on whenever you need it.": {
    de: "Ihre Skills und Agenten stehen in jeder Anfrage, obwohl in 30 Tagen keiner genutzt wurde. Ausgeschaltet kannst du ein Plugin jederzeit wieder einschalten.",
    fr: "Leurs skills et agents figurent dans chaque requête, alors qu'aucun n'a servi en 30 jours. Désactivé, un plugin peut être réactivé dès que vous en avez besoin.",
    es: "Sus skills y agentes aparecen en cada solicitud, aunque ninguno se usó en 30 días. Desactivado, puedes volver a activar un plugin cuando lo necesites.",
  },
  "Their tool names and instructions go into every session. Claude Code turns them off all at once; when you use one of them, disconnect the others on claude.ai instead.": {
    de: "Ihre Toolnamen und Anweisungen gehen in jede Sitzung. Claude Code schaltet sie nur alle zusammen aus; nutzt du einen davon, trenne stattdessen die anderen auf claude.ai.",
    fr: "Les noms de leurs outils et leurs instructions vont dans chaque session. Claude Code ne les désactive que tous ensemble ; si vous en utilisez un, déconnectez plutôt les autres sur claude.ai.",
    es: "Los nombres de sus herramientas y sus instrucciones van en cada sesión. Claude Code solo los desactiva todos a la vez; si usas uno, desconecta los demás en claude.ai.",
  },
  "Their tools load into every session, and no session called them in 30 days.": {
    de: "Ihre Tools laden in jede Sitzung, und keine Sitzung hat sie in 30 Tagen aufgerufen.",
    fr: "Leurs outils se chargent dans chaque session, et aucune session ne les a appelés en 30 jours.",
    es: "Sus herramientas se cargan en cada sesión, y ninguna sesión las llamó en 30 días.",
  },
  "Each server's tools go with every request. The agent keeps no record of which ones you use: turn off those you do not need.": {
    de: "Die Tools jedes Servers gehen mit jeder Anfrage mit. Der Agent hält nicht fest, welche du nutzt: schalte aus, was du nicht brauchst.",
    fr: "Les outils de chaque serveur accompagnent chaque requête. L'agent ne note pas lesquels vous utilisez : désactivez ceux dont vous n'avez pas besoin.",
    es: "Las herramientas de cada servidor acompañan cada solicitud. El agente no registra cuáles usas: desactiva las que no necesites.",
  },
  "This file goes with every session. Keep in it what applies everywhere; project rules belong in the project's own file.": {
    de: "Diese Datei geht in jede Sitzung. Behalte darin, was überall gilt; Regeln für ein Projekt gehören in dessen eigene Datei.",
    fr: "Ce fichier accompagne chaque session. Gardez-y ce qui vaut partout ; les règles d'un projet vont dans le fichier de ce projet.",
    es: "Este archivo acompaña cada sesión. Deja en él lo que vale en todas partes; las reglas de un proyecto van en el archivo de ese proyecto.",
  },
  "A full conversation is then sent again with every request until the window runs out; with auto-compact the agent summarizes it first.": {
    de: "Ein volles Gespräch geht dann mit jeder Anfrage erneut mit, bis das Fenster voll ist; mit Auto-Compact fasst der Agent es vorher zusammen.",
    fr: "Une conversation pleine est alors renvoyée à chaque requête jusqu'à ce que la fenêtre soit pleine ; avec l'auto-compact, l'agent la résume d'abord.",
    es: "Una conversación llena se envía entonces de nuevo con cada solicitud hasta que se llena la ventana; con auto-compact el agente la resume antes.",
  },
  "About {n} tokens per request": {
    de: "Etwa {n} Tokens pro Anfrage",
    fr: "Environ {n} tokens par requête",
    es: "Unos {n} tokens por solicitud",
  },
  "Stays: {items}": {
    de: "Bleibt: {items}",
    fr: "Reste : {items}",
    es: "Se queda: {items}",
  },
  "Setting: {where}": {
    de: "Einstellung: {where}",
    fr: "Réglage : {where}",
    es: "Ajuste: {where}",
  },
  "Use in sessions Nook starts": {
    de: "In Sitzungen verwenden, die Nook startet",
    fr: "Utiliser dans les sessions lancées par Nook",
    es: "Usar en las sesiones que inicia Nook",
  },
  "Nook passes this to Claude Code when it starts a session, without changing your own settings. It applies from the next session.": {
    de: "Nook gibt das Claude Code beim Start einer Sitzung mit, ohne deine eigenen Einstellungen zu ändern. Es gilt ab der nächsten Sitzung.",
    fr: "Nook le transmet à Claude Code au lancement d'une session, sans modifier vos propres réglages. Cela vaut à partir de la session suivante.",
    es: "Nook se lo pasa a Claude Code al iniciar una sesión, sin cambiar tus propios ajustes. Vale desde la siguiente sesión.",
  },
  "Open page": {
    de: "Seite öffnen",
    fr: "Ouvrir la page",
    es: "Abrir página",
  },
  "Show file": {
    de: "Datei zeigen",
    fr: "Afficher le fichier",
    es: "Mostrar archivo",
  },
};
