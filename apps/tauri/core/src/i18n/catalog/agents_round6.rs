//! Agents round 6: hunks, the agent's task list, a fresh conversation after a lost or overfull one, agent updates.

use super::Row;

pub const ROWS: &[Row] = &[
    (
        "This hunk could not be found in the diff.",
        "Dieser Block wurde im Diff nicht gefunden.",
        "Ce bloc est introuvable dans le diff.",
        "No se encontró este bloque en el diff.",
    ),
    (
        "This conversation no longer fits in {agent}'s context. Nook started a new one from the timeline and sent your message again.",
        "Dieses Gespräch passt nicht mehr in den Kontext von {agent}. Nook hat aus der Zeitleiste ein neues begonnen und deine Nachricht erneut gesendet.",
        "Cette conversation ne tient plus dans le contexte de {agent}. Nook en a commencé une nouvelle à partir de la chronologie et a renvoyé votre message.",
        "Esta conversación ya no cabe en el contexto de {agent}. Nook empezó una nueva a partir de la cronología y volvió a enviar tu mensaje.",
    ),
    (
        "{agent} no longer has this conversation. Nook started a new one from the timeline and sent your message again.",
        "{agent} hat dieses Gespräch nicht mehr. Nook hat aus der Zeitleiste ein neues begonnen und deine Nachricht erneut gesendet.",
        "{agent} n'a plus cette conversation. Nook en a commencé une nouvelle à partir de la chronologie et a renvoyé votre message.",
        "{agent} ya no tiene esta conversación. Nook empezó una nueva a partir de la cronología y volvió a enviar tu mensaje.",
    ),
    (
        "Nook can't tell how this program was installed. Update it the way you installed it.",
        "Nook kann nicht erkennen, wie dieses Programm installiert wurde. Aktualisiere es so, wie du es installiert hast.",
        "Nook ne sait pas comment ce programme a été installé. Mettez-le à jour comme vous l’avez installé.",
        "Nook no sabe cómo se instaló este programa. Actualízalo como lo instalaste.",
    ),
    (
        "{agent} isn't installed on this computer.",
        "{agent} ist nicht auf diesem Computer installiert.",
        "{agent} n’est pas installé sur cet ordinateur.",
        "{agent} no está instalado en este ordenador.",
    ),
    (
        "Nook restarted, so this approval expired: {summary}. Send a message to go on.",
        "Nook wurde neu gestartet, daher ist diese Freigabe abgelaufen: {summary}. Schick eine Nachricht, um weiterzumachen.",
        "Nook a redémarré, cette autorisation a donc expiré : {summary}. Envoie un message pour continuer.",
        "Nook se reinició, así que esta aprobación caducó: {summary}. Envía un mensaje para continuar.",
    ),
    (
        "Nook opened again: the session continues.",
        "Nook wurde wieder geöffnet: Die Sitzung wird fortgesetzt.",
        "Nook a été rouvert : la session continue.",
        "Nook se volvió a abrir: la sesión continúa.",
    ),
];
