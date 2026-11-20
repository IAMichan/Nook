//! The third Agents wave of Windows parity: forks, rolling back the conversation, skills.

use super::Row;

pub const ROWS: &[Row] = &[
    ("Fork of {title}", "Fork von {title}", "Duplication de {title}", "Bifurcación de {title}"),
    (
        "Fork of \"{title}\": the agent continues in a copy of its own conversation.",
        "Fork von „{title}“: Der Agent macht in einer Kopie seines eigenen Gesprächs weiter.",
        "Duplication de « {title} » : l’agent continue dans une copie de sa propre conversation.",
        "Bifurcación de “{title}”: el agente continúa en una copia de su propia conversación.",
    ),
    (
        "Fork of \"{title}\": the agent starts from a summary of what happened.",
        "Fork von „{title}“: Der Agent startet mit einer Zusammenfassung des Bisherigen.",
        "Duplication de « {title} » : l’agent part d’un résumé de ce qui s’est passé.",
        "Bifurcación de “{title}”: el agente parte de un resumen de lo ocurrido.",
    ),
    (
        "Files and conversation restored to an earlier point. The agent no longer remembers the later messages.",
        "Dateien und Gespräch auf einen früheren Stand zurückgesetzt. Der Agent erinnert sich nicht mehr an die späteren Nachrichten.",
        "Fichiers et conversation restaurés à un point antérieur. L’agent ne se souvient plus des messages suivants.",
        "Archivos y conversación restaurados a un punto anterior. El agente ya no recuerda los mensajes posteriores.",
    ),
    (
        "The agent's conversation could not be rolled back: {reason}",
        "Das Gespräch des Agenten konnte nicht zurückgesetzt werden: {reason}",
        "La conversation de l’agent n’a pas pu être restaurée : {reason}",
        "No se pudo restaurar la conversación del agente: {reason}",
    ),
    (
        "Codex runs through codex exec, which cannot roll back its conversation.",
        "Codex läuft über codex exec, das sein Gespräch nicht zurücksetzen kann.",
        "Codex passe par codex exec, qui ne peut pas restaurer sa conversation.",
        "Codex funciona con codex exec, que no puede restaurar su conversación.",
    ),
    (
        "This session can't go back to before this message.",
        "Diese Sitzung kann nicht bis vor diese Nachricht zurück.",
        "Cette session ne peut pas revenir à avant ce message.",
        "Esta sesión no puede volver a antes de este mensaje.",
    ),
    (
        "Went back to before your message. The files stayed as they were.",
        "Bis vor deine Nachricht zurückgegangen. Die Dateien sind geblieben, wie sie waren.",
        "Retour à avant votre message. Les fichiers sont restés tels quels.",
        "Se volvió a antes de tu mensaje. Los archivos se quedaron como estaban.",
    ),
];
