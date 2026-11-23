// German, French and Spanish for the restart notes and the started-by link (`ws.question.*`, `launched.by`,
// `settings.ws.continueAfterRelaunch` on the Mac).
import type { Table } from "./catalog";

export const table: Table = {
  "Started by an agent in {title}": { de: "Von einem Agenten gestartet in {title}", fr: "Lancée par un agent dans {title}", es: "Iniciada por un agente en {title}" },
  "Asked before Nook restarted. Your answer goes to the agent as a message and picks the conversation up again.": { de: "Gefragt, bevor Nook neu startete. Deine Antwort geht als Nachricht an den Agenten und nimmt das Gespräch wieder auf.", fr: "Posée avant le redémarrage de Nook. Ta réponse part en message vers l’agent et reprend la conversation.", es: "Preguntada antes de que Nook se reiniciara. Tu respuesta llega al agente como mensaje y retoma la conversación." },
  "Leave this question unanswered": { de: "Diese Frage unbeantwortet lassen", fr: "Laisser cette question sans réponse", es: "Dejar esta pregunta sin responder" },
  "Continue a session that quitting or restarting Nook stopped when you open Nook again": { de: "Eine Sitzung, die durch Beenden oder Neustarten von Nook stoppte, beim nächsten Öffnen von Nook fortsetzen", fr: "Reprendre une session arrêtée en quittant ou en redémarrant Nook quand vous le rouvrez", es: "Continuar una sesión detenida al salir de Nook o reiniciarlo cuando vuelvas a abrirlo" },
};
