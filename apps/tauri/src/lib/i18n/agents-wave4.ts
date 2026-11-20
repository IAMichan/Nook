// German, French, and Spanish for the fourth Agents wave: conversation rollback / "Edit from here" (AG-62) and
// the per-session right side panel with tabs (AG-100), matching macOS `I18n+Agents.swift`, `I18n+DiffReview.swift`,
// `I18n+FileViewer.swift`, and `I18n+Languages.swift`.
import type { Table } from "./catalog";

export const table: Table = {
  // AG-62: Conversation rollback & "Edit from here"
  "Edit from here": { de: "Ab hier bearbeiten", fr: "Modifier à partir d’ici", es: "Editar desde aquí" },
  "Write this message again?": { de: "Diese Nachricht neu schreiben?", fr: "Réécrire ce message ?", es: "¿Volver a escribir este mensaje?" },
  "The conversation goes back to before \"{message}\" and the message is back in the composer. The files can stay as they are now or go back too.": {
    de: "Das Gespräch geht zurück bis vor „{message}“ und die Nachricht steht wieder im Eingabefeld. Die Dateien können bleiben, wie sie jetzt sind, oder mit zurückgehen.",
    fr: "La conversation revient à avant « {message} » et le message retourne dans le champ de saisie. Les fichiers peuvent rester tels qu’ils sont ou revenir eux aussi.",
    es: "La conversación vuelve a antes de «{message}» y el mensaje vuelve al campo de texto. Los archivos pueden quedarse como están o volver también.",
  },
  "The conversation goes back to before \"{message}\" and the message is back in the composer. The files stay as they are now.": {
    de: "Das Gespräch geht zurück bis vor „{message}“ und die Nachricht steht wieder im Eingabefeld. Die Dateien bleiben, wie sie jetzt sind.",
    fr: "La conversation revient à avant « {message} » et le message retourne dans le champ de saisie. Les fichiers restent tels qu’ils sont.",
    es: "La conversación vuelve a antes de «{message}» y el mensaje vuelve al campo de texto. Los archivos se quedan como están.",
  },
  "Keep file changes": { de: "Dateien behalten", fr: "Garder les fichiers", es: "Conservar archivos" },
  "Revert files too": { de: "Dateien auch zurücksetzen", fr: "Rétablir aussi les fichiers", es: "Revertir también los archivos" },
  "This session can't go back to before this message.": {
    de: "Diese Sitzung kann nicht bis vor diese Nachricht zurück.",
    fr: "Cette session ne peut pas revenir à avant ce message.",
    es: "Esta sesión no puede volver a antes de este mensaje.",
  },
  "Went back to before your message. The files stayed as they were.": {
    de: "Bis vor deine Nachricht zurückgegangen. Die Dateien sind geblieben, wie sie waren.",
    fr: "Retour à avant votre message. Les fichiers sont restés tels quels.",
    es: "Se volvió a antes de tu mensaje. Los archivos se quedaron como estaban.",
  },
  "Files and conversation restored to an earlier point. The agent no longer remembers the later messages.": {
    de: "Dateien und Gespräch auf einen früheren Stand zurückgesetzt. Der Agent erinnert sich nicht mehr an die späteren Nachrichten.",
    fr: "Fichiers et conversation restaurés à un point antérieur. L’agent ne se souvient plus des messages suivants.",
    es: "Archivos y conversación restaurados a un punto anterior. El agente ya no recuerda los mensajes posteriores.",
  },
  "The files in this worktree and the conversation go back to how they were before “{message}”. Later changes are lost and the agent forgets the later messages.": {
    de: "Die Dateien in diesem Worktree und das Gespräch gehen auf den Stand vor „{message}“ zurück. Spätere Änderungen gehen verloren und der Agent vergisst die späteren Nachrichten.",
    fr: "Les fichiers de ce worktree et la conversation reviennent à leur état d’avant « {message} ». Les modifications ultérieures sont perdues et l’agent oublie les messages suivants.",
    es: "Los archivos de este worktree y la conversación vuelven a como estaban antes de «{message}». Los cambios posteriores se pierden y el agente olvida los mensajes posteriores.",
  },

  // AG-100: Per-session right side panel with tabs
  "Side panel": { de: "Seitenleiste", fr: "Panneau latéral", es: "Panel lateral" },
  "Open side panel": { de: "Seitenleiste öffnen", fr: "Ouvrir le panneau latéral", es: "Abrir el panel lateral" },
  "Close side panel": { de: "Seitenleiste schließen", fr: "Fermer le panneau latéral", es: "Cerrar el panel lateral" },
  "Resize side panel": { de: "Breite der Seitenleiste ändern", fr: "Redimensionner le panneau latéral", es: "Cambiar el ancho del panel lateral" },
  "Maximize panel": { de: "Bereich maximieren", fr: "Agrandir le panneau", es: "Maximizar el panel" },
  "Restore panel": { de: "Bereich verkleinern", fr: "Réduire le panneau", es: "Restaurar el panel" },
  "New tab": { de: "Neuer Tab", fr: "Nouvel onglet", es: "Nueva pestaña" },
  "Close tab": { de: "Tab schließen", fr: "Fermer l’onglet", es: "Cerrar pestaña" },
  "Open a tool": { de: "Werkzeug öffnen", fr: "Ouvrir un outil", es: "Abrir una herramienta" },
  "Needs a folder for this session": { de: "Braucht einen Ordner für diese Sitzung", fr: "Nécessite un dossier pour cette session", es: "Necesita una carpeta para esta sesión" },
  "Plans": { de: "Pläne", fr: "Plans", es: "Planes" },
  "Plan {n}": { de: "Plan {n}", fr: "Plan {n}", es: "Plan {n}" },
  "Subagents": { de: "Subagenten", fr: "Sous-agents", es: "Subagentes" },
  "Terminal": { de: "Terminal", fr: "Terminal", es: "Terminal" },
  "Pull request": { de: "Pull Request", fr: "Pull request", es: "Pull request" },
  "File": { de: "Datei", fr: "Fichier", es: "Archivo" },
  "Files": { de: "Dateien", fr: "Fichiers", es: "Archivos" },
  "Plans, tasks and files the agent made in this session": {
    de: "Pläne, Aufgaben und Dateien, die der Agent in dieser Sitzung erstellt hat",
    fr: "Plans, tâches et fichiers créés par l’agent dans cette session",
    es: "Planes, tareas y archivos que el agente creó en esta sesión",
  },
  "The subagents the agent started: their task, how they went about it and their answer": {
    de: "Die Subagenten, die der Agent gestartet hat: ihr Auftrag, ihr Vorgehen und ihre Antwort",
    fr: "Les sous-agents lancés par l’agent : leur tâche, leur démarche et leur réponse",
    es: "Los subagentes que inició el agente: su tarea, cómo la abordaron y su respuesta",
  },
  "Terminal in this session's folder": {
    de: "Terminal im Ordner dieser Sitzung",
    fr: "Terminal dans le dossier de cette session",
    es: "Terminal en la carpeta de esta sesión",
  },
  "Browser next to this session": {
    de: "Browser neben dieser Sitzung",
    fr: "Navigateur à côté de cette session",
    es: "Navegador junto a esta sesión",
  },
  "Changes in this session's folder": {
    de: "Änderungen im Ordner dieser Sitzung",
    fr: "Modifications dans le dossier de cette session",
    es: "Cambios en la carpeta de esta sesión",
  },
  "A pull request beside this session: the one for its branch, one of yours, or one from a link": {
    de: "Ein Pull Request neben dieser Sitzung: der ihres Branches, einer von dir oder einer aus einem Link",
    fr: "Une pull request à côté de cette session : celle de sa branche, l’une des vôtres ou celle d’un lien",
    es: "Una pull request junto a esta sesión: la de su rama, una tuya o la de un enlace",
  },
  "Files in this session's folder": {
    de: "Dateien im Ordner dieser Sitzung",
    fr: "Fichiers dans le dossier de cette session",
    es: "Archivos en la carpeta de esta sesión",
  },
  "No git repository": { de: "Kein Git-Repository", fr: "Aucun dépôt git", es: "Sin repositorio git" },
  "This session isn't in a git repository. Make it a git repository to see changes and diffs here.": {
    de: "Diese Sitzung liegt nicht in einem Git-Repository. Mach es zu einem Git-Repository, um hier Änderungen und Diffs zu sehen.",
    fr: "Cette session n’est pas dans un dépôt git. Faites-en un dépôt git pour voir les modifications et les diffs ici.",
    es: "Esta sesión no está en un repositorio git. Conviértela en un repositorio git para ver aquí los cambios y diffs.",
  },
  "No plans or files yet": { de: "Noch keine Pläne oder Dateien", fr: "Aucun plan ni fichier pour l’instant", es: "Todavía no hay planes ni archivos" },
  "Plans and files the agent creates in this session show up here.": {
    de: "Pläne und Dateien, die der Agent in dieser Sitzung erstellt, erscheinen hier.",
    fr: "Les plans et fichiers que l’agent crée dans cette session s’affichent ici.",
    es: "Los planes y archivos que el agente cree en esta sesión aparecerán aquí.",
  },
  "No subagents": { de: "Keine Subagenten", fr: "Aucun sous-agent", es: "Sin subagentes" },
  "Subagents the agent starts during this session show up here with their task and answer.": {
    de: "Subagenten, die der Agent während dieser Sitzung startet, erscheinen hier mit ihrem Auftrag und ihrer Antwort.",
    fr: "Les sous-agents que l’agent lance pendant cette session s’affichent ici avec leur tâche et leur réponse.",
    es: "Los subagentes que el agente inicie durante esta sesión aparecerán aquí con su tarea y su respuesta.",
  },
  "Task": { de: "Auftrag", fr: "Tâche", es: "Tarea" },
  "Answer": { de: "Antwort", fr: "Réponse", es: "Respuesta" },
  "Search file in this folder…": {
    de: "Datei in diesem Ordner suchen…",
    fr: "Rechercher un fichier dans ce dossier…",
    es: "Buscar archivo en esta carpeta…",
  },
  "Loading files…": { de: "Dateien werden geladen…", fr: "Chargement des fichiers…", es: "Cargando archivos…" },
  "No file open": { de: "Keine Datei geöffnet", fr: "Aucun fichier ouvert", es: "Ningún archivo abierto" },
  "Click a file link in the conversation, or open any file (a .env too) to read or edit it here.": {
    de: "Klicke im Gespräch auf einen Dateilink oder öffne selbst eine Datei (auch eine .env), um sie hier zu lesen oder zu bearbeiten.",
    fr: "Cliquez sur un lien de fichier dans la conversation, ou ouvrez un fichier (un .env aussi) pour le lire ou le modifier ici.",
    es: "Haz clic en un enlace de archivo de la conversación, o abre cualquier archivo (también un .env) para leerlo o editarlo aquí.",
  },
};
