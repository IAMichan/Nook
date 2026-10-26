import Foundation

// Texts for a session's conversation and its composer: the line above what is new since your last visit, the context
// meter's suggestion. Numbers use %ld, text uses %@.

let chatTimelineTranslations: [AppLanguage: [String: String]] = [
    .nl: [
        "timeline.newSince": "Nieuw sinds je laatste bezoek",
        "compose.context.nearlyFull": "Het contextvenster raakt vol: /compact vat het gesprek samen.",
    ],
    .en: [
        "timeline.newSince": "New since your last visit",
        "compose.context.nearlyFull": "The context window is filling up: /compact summarizes the conversation.",
    ],
    .de: [
        "timeline.newSince": "Neu seit deinem letzten Besuch",
        "compose.context.nearlyFull": "Das Kontextfenster wird voll: /compact fasst das Gespräch zusammen.",
    ],
    .fr: [
        "timeline.newSince": "Nouveau depuis ta dernière visite",
        "compose.context.nearlyFull": "La fenêtre de contexte se remplit : /compact résume la conversation.",
    ],
    .es: [
        "timeline.newSince": "Nuevo desde tu última visita",
        "compose.context.nearlyFull": "La ventana de contexto se está llenando: /compact resume la conversación.",
    ],
]
