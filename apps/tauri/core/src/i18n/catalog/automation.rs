//! Scheduled tasks, webhooks, handing a session to another agent and delegated sessions.

use super::Row;

pub const ROWS: &[Row] = &[
    ("This session no longer exists.", "Diese Sitzung gibt es nicht mehr.", "Cette session n’existe plus.", "Esta sesión ya no existe."),
    (
        "Not while the agent works. Wait for the turn to finish, or stop it.",
        "Nicht, solange der Agent arbeitet. Warte, bis die Runde fertig ist, oder stoppe ihn.",
        "Pas pendant que l’agent travaille. Attends la fin du tour, ou arrête-le.",
        "No mientras el agente trabaja. Espera a que termine el turno o detenlo.",
    ),
    (
        "{agent} is not on this computer.",
        "{agent} ist nicht auf diesem Computer.",
        "{agent} n’est pas sur cet ordinateur.",
        "{agent} no está en este ordenador.",
    ),
    (
        "This session already runs with that agent.",
        "Diese Sitzung läuft schon mit diesem Agenten.",
        "Cette session tourne déjà avec cet agent.",
        "Esta sesión ya funciona con ese agente.",
    ),
    ("Handed over from {from} to {to}.", "Von {from} an {to} übergeben.", "Transmise de {from} à {to}.", "Traspasada de {from} a {to}."),
    (
        "Context handoff: {included} items go along with your next message, {omitted} older ones do not.",
        "Kontextübergabe: {included} Einträge gehen mit deiner nächsten Nachricht mit, {omitted} ältere nicht.",
        "Transmission du contexte : {included} éléments partent avec ton prochain message, {omitted} plus anciens non.",
        "Traspaso de contexto: {included} elementos van con tu próximo mensaje, {omitted} más antiguos no.",
    ),
    (
        "Fresh conversation for the scheduled task “{title}”: the agent does not see earlier runs.",
        "Neues Gespräch für die geplante Aufgabe „{title}“: Der Agent sieht frühere Läufe nicht.",
        "Nouvelle conversation pour la tâche planifiée « {title} » : l’agent ne voit pas les exécutions précédentes.",
        "Conversación nueva para la tarea programada «{title}»: el agente no ve las ejecuciones anteriores.",
    ),
    ("Delegated by “{parent}”", "Delegiert von „{parent}“", "Déléguée par « {parent} »", "Delegada por «{parent}»"),
    ("Invalid id.", "Ungültige ID.", "Identifiant non valide.", "Id no válido."),
    ("Write a prompt.", "Schreib einen Prompt.", "Écris un prompt.", "Escribe un prompt."),
    (
        "The secret could not be kept in the secret store.",
        "Das Geheimnis konnte nicht im Schlüsselbund gespeichert werden.",
        "Le secret n’a pas pu être gardé dans le trousseau.",
        "El secreto no se pudo guardar en el almacén de secretos.",
    ),
];
