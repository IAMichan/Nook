import Foundation

// Texts for what the Agents tab took in its third round: the task list, subagents, splitting from a message,
// watching a pull request, diff comments, the minimap and previews, export, other agents and remote machines.
// Numbers use %ld, text uses %@.

let parityTranslations: [AppLanguage: [String: String]] = [
    .nl: [
        "ws.subagents.title": "Subagents",
        "ws.subagents.progress": "%ld van %ld klaar",
        "ws.tasks.title": "Taken",
        "ws.tasks.accessibility": "Taken: %ld van %ld klaar. Nu: %@",
    ],
    .en: [
        "ws.subagents.title": "Subagents",
        "ws.subagents.progress": "%ld of %ld done",
        "ws.tasks.title": "Tasks",
        "ws.tasks.accessibility": "Tasks: %ld of %ld done. Now: %@",
    ],
    .de: [
        "ws.subagents.title": "Subagenten",
        "ws.subagents.progress": "%ld von %ld fertig",
        "ws.tasks.title": "Aufgaben",
        "ws.tasks.accessibility": "Aufgaben: %ld von %ld erledigt. Jetzt: %@",
    ],
    .fr: [
        "ws.subagents.title": "Sous-agents",
        "ws.subagents.progress": "%ld sur %ld terminés",
        "ws.tasks.title": "Tâches",
        "ws.tasks.accessibility": "Tâches : %ld sur %ld terminées. En cours : %@",
    ],
    .es: [
        "ws.subagents.title": "Subagentes",
        "ws.subagents.progress": "%ld de %ld hechos",
        "ws.tasks.title": "Tareas",
        "ws.tasks.accessibility": "Tareas: %ld de %ld hechas. Ahora: %@",
    ],
]
