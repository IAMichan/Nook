// German, French, and Spanish for ten Mac features ported together: the first-run "Coding agents" step
// (`OnboardingAgentsStep`), closing several pull requests (`PullRequestBatchClose`), the undo line under the session list
// (`UndoLog`), comparing models (`ModelComparison`), session links (`SessionLink`) and the usage limit card's account
// advice (`LimitAdvisor`).
import type { Table } from "./catalog";

export const table: Table = {
  // First-run flow: Coding agents
  "Coding agents": { de: "Coding-Agents", fr: "Agents de code", es: "Agentes de código" },
  "Nook starts and follows your coding agents. One that is ready is enough to begin; installing and signing in happens in a terminal you can see.": { de: "Nook startet und begleitet deine Coding-Agents. Einer, der bereit ist, reicht für den Anfang; Installieren und Anmelden passiert in einem Terminal, das du siehst.", fr: "Nook lance et suit vos agents de code. Un seul prêt suffit pour commencer ; l’installation et la connexion se font dans un terminal visible.", es: "Nook inicia y sigue a tus agentes de código. Con uno listo basta para empezar; instalar e iniciar sesión ocurre en un terminal que ves." },
  "Nook is checking for it…": { de: "Nook sieht nach…", fr: "Nook vérifie…", es: "Nook lo está comprobando…" },
  "Working in the terminal…": { de: "Läuft im Terminal…", fr: "En cours dans le terminal…", es: "En curso en el terminal…" },
  "Installed, not signed in yet": { de: "Installiert, noch nicht angemeldet", fr: "Installé, pas encore connecté", es: "Instalado, aún sin iniciar sesión" },
  "Not on this computer": { de: "Nicht auf diesem Computer", fr: "Pas sur cet ordinateur", es: "No está en este ordenador" },
  "Ready to start": { de: "Bereit zum Start", fr: "Prêt à démarrer", es: "Listo para empezar" },
  "Couldn't open the terminal": { de: "Das Terminal konnte nicht geöffnet werden", fr: "Impossible d’ouvrir le terminal", es: "No se pudo abrir el terminal" },
  "Couldn't add the project": { de: "Das Projekt konnte nicht hinzugefügt werden", fr: "Impossible d’ajouter le projet", es: "No se pudo añadir el proyecto" },
  "Add another agent (ACP) in Settings › Agents": { de: "Einen weiteren Agent (ACP) in Einstellungen › Agents hinzufügen", fr: "Ajouter un autre agent (ACP) dans Réglages › Agents", es: "Añadir otro agente (ACP) en Ajustes › Agentes" },
  "Recent projects": { de: "Letzte Projekte", fr: "Projets récents", es: "Proyectos recientes" },
  "Git folders you worked in over the last 30 days. Adding only remembers them as a project.": { de: "Git-Ordner, in denen du in den letzten 30 Tagen gearbeitet hast. Hinzufügen merkt sie nur als Projekt.", fr: "Les dossiers git où vous avez travaillé ces 30 derniers jours. Les ajouter les retient seulement comme projet.", es: "Carpetas git en las que trabajaste en los últimos 30 días. Añadirlas solo las recuerda como proyecto." },
  "{n} sessions": { de: "{n} Sitzungen", fr: "{n} sessions", es: "{n} sesiones" },
  "Added": { de: "Hinzugefügt", fr: "Ajouté", es: "Añadido" },

  // Closing several pull requests
  "{n} pull requests closed": { de: "{n} Pull-Requests geschlossen", fr: "{n} pull requests fermées", es: "{n} pull requests cerradas" },
  "{closed} of {total} pull requests closed": { de: "{closed} von {total} Pull-Requests geschlossen", fr: "{closed} sur {total} pull requests fermées", es: "{closed} de {total} pull requests cerradas" },
  "{name}: comment refused, stays open ({reason})": { de: "{name}: Kommentar abgelehnt, bleibt offen ({reason})", fr: "{name} : commentaire refusé, reste ouverte ({reason})", es: "{name}: comentario rechazado, sigue abierta ({reason})" },
  "Closing failed": { de: "Schließen fehlgeschlagen", fr: "La fermeture a échoué", es: "No se pudo cerrar" },
  "Done selecting": { de: "Auswahl fertig", fr: "Sélection terminée", es: "Selección terminada" },
  "Select pull requests to close": { de: "Pull-Requests zum Schließen auswählen", fr: "Choisir des pull requests à fermer", es: "Elegir pull requests para cerrar" },
  "Select": { de: "Auswählen", fr: "Sélectionner", es: "Seleccionar" },
  "{n} chosen": { de: "{n} gewählt", fr: "{n} choisies", es: "{n} elegidas" },
  "Choose open pull requests to close": { de: "Wähle offene Pull-Requests zum Schließen", fr: "Choisissez des pull requests ouvertes à fermer", es: "Elige pull requests abiertas para cerrar" },
  "Comment on why (optional)": { de: "Kommentar, warum (optional)", fr: "Commentaire sur la raison (facultatif)", es: "Comentario sobre el motivo (opcional)" },
  "Close {n} pull requests without merging?": { de: "{n} Pull-Requests ohne Zusammenführen schließen?", fr: "Fermer {n} pull requests sans fusionner ?", es: "¿Cerrar {n} pull requests sin fusionar?" },
  "Your comment is posted first; a pull request where that fails stays open.": { de: "Dein Kommentar wird zuerst gepostet; ein Pull-Request, bei dem das fehlschlägt, bleibt offen.", fr: "Votre commentaire est publié d’abord ; une pull request où cela échoue reste ouverte.", es: "Tu comentario se publica primero; una pull request en la que falle sigue abierta." },
  "Close {n}": { de: "{n} schließen", fr: "Fermer {n}", es: "Cerrar {n}" },
  "Choose to close": { de: "Zum Schließen wählen", fr: "Choisir pour fermer", es: "Elegir para cerrar" },

  // The undo line under the session list
  "Session settled": { de: "Sitzung erledigt", fr: "Session réglée", es: "Sesión resuelta" },
  "{n} sessions settled": { de: "{n} Sitzungen erledigt", fr: "{n} sessions réglées", es: "{n} sesiones resueltas" },
  "Session reopened": { de: "Sitzung wieder offen", fr: "Session rouverte", es: "Sesión reabierta" },
  "{n} sessions reopened": { de: "{n} Sitzungen wieder offen", fr: "{n} sessions rouvertes", es: "{n} sesiones reabiertas" },
  "Session snoozed": { de: "Sitzung zurückgestellt", fr: "Session mise en pause", es: "Sesión pospuesta" },
  "{n} sessions snoozed": { de: "{n} Sitzungen zurückgestellt", fr: "{n} sessions mises en pause", es: "{n} sesiones pospuestas" },
  "Session pinned": { de: "Sitzung angeheftet", fr: "Session épinglée", es: "Sesión fijada" },
  "{n} sessions pinned": { de: "{n} Sitzungen angeheftet", fr: "{n} sessions épinglées", es: "{n} sesiones fijadas" },
  "Session unpinned": { de: "Sitzung gelöst", fr: "Session désépinglée", es: "Sesión desfijada" },
  "{n} sessions unpinned": { de: "{n} Sitzungen gelöst", fr: "{n} sessions désépinglées", es: "{n} sesiones desfijadas" },

  // Comparing models
  "{n} sessions started": { de: "{n} Sitzungen gestartet", fr: "{n} sessions lancées", es: "{n} sesiones iniciadas" },
  "Compare models": { de: "Modelle vergleichen", fr: "Comparer des modèles", es: "Comparar modelos" },
  "Send the same prompt to more models, each in a worktree of its own": { de: "Denselben Prompt an weitere Modelle senden, jedes in einem eigenen Worktree", fr: "Envoyer le même prompt à d’autres modèles, chacun dans son propre worktree", es: "Enviar el mismo prompt a más modelos, cada uno en su propio worktree" },
  "{n} models": { de: "{n} Modelle", fr: "{n} modèles", es: "{n} modelos" },
  "Also send to (at most {n} together)": { de: "Auch senden an (höchstens {n} zusammen)", fr: "Envoyer aussi à (au plus {n} ensemble)", es: "Enviar también a (como mucho {n} juntos)" },
  "This model is already chosen.": { de: "Dieses Modell ist schon gewählt.", fr: "Ce modèle est déjà choisi.", es: "Este modelo ya está elegido." },
  "At most {n} models at once.": { de: "Höchstens {n} Modelle auf einmal.", fr: "Au plus {n} modèles à la fois.", es: "Como mucho {n} modelos a la vez." },
  "Don't compare": { de: "Nicht vergleichen", fr: "Ne pas comparer", es: "No comparar" },

  // Session links
  "Copy session link": { de: "Sitzungslink kopieren", fr: "Copier le lien de la session", es: "Copiar enlace de la sesión" },
  "Session link copied": { de: "Sitzungslink kopiert", fr: "Lien de la session copié", es: "Enlace de la sesión copiado" },
  "Paste it in a composer to point at this session.": { de: "Füge ihn in einen Composer ein, um auf diese Sitzung zu verweisen.", fr: "Collez-le dans un compositeur pour désigner cette session.", es: "Pégalo en un compositor para señalar esta sesión." },
  "Could not copy the link": { de: "Der Link konnte nicht kopiert werden", fr: "Impossible de copier le lien", es: "No se pudo copiar el enlace" },

  // Usage limit card
  "Switch this session to {account} ({used}% used) and continue immediately.": { de: "Diese Sitzung zu {account} wechseln ({used} % genutzt) und sofort weitermachen.", fr: "Passer cette session sur {account} ({used} % utilisé) et continuer tout de suite.", es: "Cambiar esta sesión a {account} ({used} % usado) y seguir enseguida." },
};
