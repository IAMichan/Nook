import Foundation

// Texts for a session's conversation and its composer: the line above what is new since your last visit, the context
// meter's suggestion, and passages of an answer quoted into the next message. Numbers use %ld, text uses %@.

let chatTimelineTranslations: [AppLanguage: [String: String]] = [
    .nl: [
        "selection.ask": "Vraag hierover",
        "compose.quote.remove": "Citaat weghalen",
        "compose.quote.full": "Er gaan al vijf citaten mee; haal er een weg om een ander toe te voegen.",
        "timeline.newSince": "Nieuw sinds je laatste bezoek",
        "compose.context.nearlyFull": "Het contextvenster raakt vol: /compact vat het gesprek samen.",
    ],
    .en: [
        "selection.ask": "Ask About This",
        "compose.quote.remove": "Remove quote",
        "compose.quote.full": "Five quotes already go with this message; remove one to add another.",
        "timeline.newSince": "New since your last visit",
        "compose.context.nearlyFull": "The context window is filling up: /compact summarizes the conversation.",
    ],
    .de: [
        "selection.ask": "Hierzu fragen",
        "compose.quote.remove": "Zitat entfernen",
        "compose.quote.full": "Es gehen schon fünf Zitate mit; entferne eins, um ein anderes hinzuzufügen.",
        "timeline.newSince": "Neu seit deinem letzten Besuch",
        "compose.context.nearlyFull": "Das Kontextfenster wird voll: /compact fasst das Gespräch zusammen.",
    ],
    .fr: [
        "selection.ask": "Poser une question à ce sujet",
        "compose.quote.remove": "Retirer la citation",
        "compose.quote.full": "Cinq citations accompagnent déjà ce message ; retires-en une pour en ajouter une autre.",
        "timeline.newSince": "Nouveau depuis ta dernière visite",
        "compose.context.nearlyFull": "La fenêtre de contexte se remplit : /compact résume la conversation.",
    ],
    .es: [
        "selection.ask": "Preguntar sobre esto",
        "compose.quote.remove": "Quitar cita",
        "compose.quote.full": "Ya van cinco citas con este mensaje; quita una para añadir otra.",
        "timeline.newSince": "Nuevo desde tu última visita",
        "compose.context.nearlyFull": "La ventana de contexto se está llenando: /compact resume la conversación.",
    ],
]
