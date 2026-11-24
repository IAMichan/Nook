//! Translations for the AG-06 / AG-09 / AG-10 / AG-11 agent MCP bridge tools.

use super::Row;

pub const ROWS: &[Row] = &[
    // Tool labels (`core/src/workspace/bridge.rs`)
    (
        "Watch pull request",
        "Pull Request beobachten",
        "Suivre la pull request",
        "Seguir la pull request",
    ),
    (
        "Pull request status",
        "Pull-Request-Status",
        "Statut de la pull request",
        "Estado de la pull request",
    ),
    (
        "Search sessions",
        "Sitzungen durchsuchen",
        "Rechercher dans les sessions",
        "Buscar en sesiones",
    ),
    (
        "Organize sessions",
        "Sitzungen organisieren",
        "Organiser les sessions",
        "Organizar sesiones",
    ),
    (
        "Session questions",
        "Sitzungsfragen",
        "Questions de session",
        "Preguntas de sesiones",
    ),
    (
        "Schedule task",
        "Aufgabe planen",
        "Planifier une tâche",
        "Programar tarea",
    ),
    (
        "Scheduled tasks",
        "Geplante Aufgaben",
        "Tâches planifiées",
        "Tareas programadas",
    ),
    (
        "Update scheduled task",
        "Geplante Aufgabe ändern",
        "Modifier la tâche planifiée",
        "Actualizar tarea programada",
    ),
    (
        "Run scheduled task now",
        "Geplante Aufgabe jetzt ausführen",
        "Exécuter la tâche planifiée maintenant",
        "Ejecutar tarea programada ahora",
    ),
    (
        "Request secret",
        "Geheimnis anfordern",
        "Demander un secret",
        "Solicitar secreto",
    ),
    // Secret submission errors (`src-tauri/src/workspace/bridge.rs`)
    (
        "Enter a secret value first.",
        "Gib zuerst einen Geheimniswert ein.",
        "Saisis d’abord une valeur secrète.",
        "Introduce primero un valor secreto.",
    ),
    (
        "This request no longer exists.",
        "Diese Anfrage existiert nicht mehr.",
        "Cette demande n’existe plus.",
        "Esta solicitud ya no existe.",
    ),
    // Session organize & questions (`src-tauri/src/workspace/bridge/sessions.rs`)
    (
        "{agent} wants to organize session “{title}” ({action})",
        "{agent} möchte die Sitzung „{title}“ organisieren ({action})",
        "{agent} veut organiser la session « {title} » ({action})",
        "{agent} quiere organizar la sesión «{title}» ({action})",
    ),
    (
        "{agent} wants to organize {n} sessions ({action})",
        "{agent} möchte {n} Sitzungen organisieren ({action})",
        "{agent} veut organiser {n} sessions ({action})",
        "{agent} quiere organizar {n} sesiones ({action})",
    ),
    (
        "This only changes how these sessions are organized in Nook.",
        "Dies ändert nur, wie diese Sitzungen in Nook geordnet sind.",
        "Cela modifie uniquement l’organisation de ces sessions dans Nook.",
        "Esto solo cambia cómo se organizan estas sesiones en Nook.",
    ),
    (
        "{agent} wants to answer a question for session “{title}”",
        "{agent} möchte eine Frage für die Sitzung „{title}“ beantworten",
        "{agent} veut répondre à une question pour la session « {title} »",
        "{agent} quiere responder una pregunta de la sesión «{title}»",
    ),
    (
        "The other agent receives these choices as the answer to its multiple-choice question.",
        "Der andere Agent erhält diese Auswahl als Antwort auf seine Multiple-Choice-Frage.",
        "L’autre agent reçoit ces choix comme réponse à sa question à choix multiples.",
        "El otro agente recibe estas opciones como respuesta a su pregunta de opción múltiple.",
    ),
    // Scheduled tasks (`src-tauri/src/workspace/bridge/schedule.rs`)
    (
        "{agent} wants to create a scheduled task: “{title}”",
        "{agent} möchte eine geplante Aufgabe erstellen: „{title}“",
        "{agent} veut créer une tâche planifiée : « {title} »",
        "{agent} quiere crear una tarea programada: «{title}»",
    ),
    (
        "Scheduled tasks run on the schedule without full Bypass rights. You can pause them anytime under Automation.",
        "Geplante Aufgaben laufen nach Zeitplan ohne volle Bypass-Rechte. Du kannst sie jederzeit unter Automatisierung pausieren.",
        "Les tâches planifiées s’exécutent selon le calendrier sans droits Bypass complets. Tu peux les mettre en pause à tout moment dans Automatisation.",
        "Las tareas programadas se ejecutan según el horario sin permisos completos de Bypass. Puedes pausarlas en cualquier momento en Automatización.",
    ),
    (
        "{agent} wants to delete the scheduled task “{title}”",
        "{agent} möchte die geplante Aufgabe „{title}“ löschen",
        "{agent} veut supprimer la tâche planifiée « {title} »",
        "{agent} quiere eliminar la tarea programada «{title}»",
    ),
    (
        "{agent} wants to update the scheduled task “{title}”",
        "{agent} möchte die geplante Aufgabe „{title}“ ändern",
        "{agent} veut modifier la tâche planifiée « {title} »",
        "{agent} quiere actualizar la tarea programada «{title}»",
    ),
    (
        "Updating or deleting a scheduled task always requires your approval.",
        "Das Ändern oder Löschen einer geplanten Aufgabe erfordert immer deine Zustimmung.",
        "La modification ou la suppression d’une tâche planifiée nécessite toujours ton autorisation.",
        "Actualizar o eliminar una tarea programada siempre requiere tu aprobación.",
    ),
    (
        "{agent} wants to run the scheduled task “{title}” now",
        "{agent} möchte die geplante Aufgabe „{title}“ jetzt ausführen",
        "{agent} veut exécuter la tâche planifiée « {title} » maintenant",
        "{agent} quiere ejecutar la tarea programada «{title}» ahora",
    ),
    (
        "The task runs once right now with its own prompt and rights.",
        "Die Aufgabe läuft jetzt einmalig mit ihrem eigenen Prompt und ihren eigenen Rechten.",
        "La tâche s’exécute une fois maintenant avec sa propre consigne et ses propres droits.",
        "La tarea se ejecuta una vez ahora mismo con su propio prompt y permisos.",
    ),
    // Request secret (`src-tauri/src/workspace/bridge/secrets.rs`)
    (
        "{agent} requests secret {name}",
        "{agent} fordert das Geheimnis {name} an",
        "{agent} demande le secret {name}",
        "{agent} solicita el secreto {name}",
    ),
    (
        "This secret is already saved in Nook (or paste a new value below). The agent receives only a private file, never the value in chat history.",
        "Dieses Geheimnis ist bereits in Nook gespeichert (oder füge unten einen neuen Wert ein). Der Agent erhält nur eine private Datei, niemals den Wert im Gesprächsverlauf.",
        "Ce secret est déjà enregistré dans Nook (ou colle une nouvelle valeur ci-dessous). L’agent reçoit uniquement un fichier privé, jamais la valeur dans l’historique.",
        "Este secreto ya está guardado en Nook (o pega un nuevo valor abajo). El agente solo recibe un archivo privado, nunca el valor en el historial.",
    ),
    (
        "This secret is already saved in Nook (or paste a new value below). Note: the agent requested the value inline.",
        "Dieses Geheimnis ist bereits in Nook gespeichert (oder füge unten einen neuen Wert ein). Hinweis: Der Agent hat den Wert direkt angefordert.",
        "Ce secret est déjà enregistré dans Nook (ou colle une nouvelle valeur ci-dessous). Remarque : l’agent a demandé la valeur directement.",
        "Este secreto ya está guardado en Nook (o pega un nuevo valor abajo). Nota: el agente solicitó el valor directamente.",
    ),
    (
        "Paste the value below to allow. Nook writes it to a private owner-only file and deletes it automatically after 24 hours.",
        "Füge den Wert unten ein, um zuzustimmen. Nook schreibt ihn in eine private Datei (nur für dich lesbar) und löscht sie nach 24 Stunden automatisch.",
        "Colle la valeur ci-dessous pour autoriser. Nook l’écrit dans un fichier privé (lisible uniquement par toi) et le supprime automatiquement après 24 heures.",
        "Pega el valor abajo para permitirlo. Nook lo guarda en un archivo privado (solo legible por ti) y lo elimina automáticamente tras 24 horas.",
    ),
    (
        "Paste the value below to allow. Note: the agent requested the value inline in its tool response.",
        "Füge den Wert unten ein, um zuzustimmen. Hinweis: Der Agent hat den Wert direkt in seiner Tool-Antwort angefordert.",
        "Colle la valeur ci-dessous pour autoriser. Remarque : l’agent a demandé la valeur directement dans la réponse de l’outil.",
        "Pega el valor abajo para permitirlo. Nota: el agente solicitó el valor directamente en la respuesta de la herramienta.",
    ),
];
