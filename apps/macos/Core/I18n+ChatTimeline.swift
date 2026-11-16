import Foundation

// Texts for a session's conversation and its composer: the line above what is new since your last visit, the context
// meter's suggestion, the account's usage limits, and passages of an answer quoted into the next message. Numbers use %ld, text uses %@.

let chatTimelineTranslations: [AppLanguage: [String: String]] = [
    .nl: [
        "compose.limits.shortHours": "%ldu",
        "compose.limits.shortWeek": "W",
        "compose.limits.shortDays": "%ldd",
        "compose.limits.help": "Limieten van %@: %@",
        "selection.ask": "Vraag hierover",
        "compose.quote.remove": "Citaat weghalen",
        "compose.quote.full": "Er gaan al vijf citaten mee; haal er een weg om een ander toe te voegen.",
        "timeline.newSince": "Nieuw sinds je laatste bezoek",
        "compose.context.nearlyFull": "Dit gesprek wordt lang: /compact vat het samen voordat het vanzelf gebeurt.",
    ],
    .en: [
        "compose.limits.shortHours": "%ldh",
        "compose.limits.shortWeek": "W",
        "compose.limits.shortDays": "%ldd",
        "compose.limits.help": "Limits of %@: %@",
        "selection.ask": "Ask About This",
        "compose.quote.remove": "Remove quote",
        "compose.quote.full": "Five quotes already go with this message; remove one to add another.",
        "timeline.newSince": "New since your last visit",
        "compose.context.nearlyFull": "This conversation is getting long: /compact summarizes it before it happens by itself.",
    ],
    .de: [
        "compose.limits.shortHours": "%ldh",
        "compose.limits.shortWeek": "W",
        "compose.limits.shortDays": "%ldT",
        "compose.limits.help": "Limits von %@: %@",
        "selection.ask": "Hierzu fragen",
        "compose.quote.remove": "Zitat entfernen",
        "compose.quote.full": "Es gehen schon fünf Zitate mit; entferne eins, um ein anderes hinzuzufügen.",
        "timeline.newSince": "Neu seit deinem letzten Besuch",
        "compose.context.nearlyFull": "Dieses Gespräch wird lang: /compact fasst es zusammen, bevor es von selbst passiert.",
    ],
    .fr: [
        "compose.limits.shortHours": "%ldh",
        "compose.limits.shortWeek": "S",
        "compose.limits.shortDays": "%ldj",
        "compose.limits.help": "Limites de %@ : %@",
        "selection.ask": "Poser une question à ce sujet",
        "compose.quote.remove": "Retirer la citation",
        "compose.quote.full": "Cinq citations accompagnent déjà ce message ; retires-en une pour en ajouter une autre.",
        "timeline.newSince": "Nouveau depuis ta dernière visite",
        "compose.context.nearlyFull": "Cette conversation devient longue : /compact la résume avant que cela se fasse tout seul.",
    ],
    .es: [
        "compose.limits.shortHours": "%ldh",
        "compose.limits.shortWeek": "S",
        "compose.limits.shortDays": "%ldd",
        "compose.limits.help": "Límites de %@: %@",
        "selection.ask": "Preguntar sobre esto",
        "compose.quote.remove": "Quitar cita",
        "compose.quote.full": "Ya van cinco citas con este mensaje; quita una para añadir otra.",
        "timeline.newSince": "Nuevo desde tu última visita",
        "compose.context.nearlyFull": "Esta conversación se está alargando: /compact la resume antes de que ocurra solo.",
    ],
]
