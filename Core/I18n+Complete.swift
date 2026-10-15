import Foundation

// Texts added while finishing the redesign (reconnect actions, approvals, onboarding, work environment).
// `I18n.lookup` searches this table first. Numbers use %ld, text uses %@.

let completionTranslations: [AppLanguage: [String: String]] = [
    .nl: [
        "connector.reconnect": "Opnieuw verbinden",
        "connector.retry": "Opnieuw proberen",
    ],
    .en: [
        "connector.reconnect": "Reconnect",
        "connector.retry": "Try again",
    ],
    .de: [
        "connector.reconnect": "Neu verbinden",
        "connector.retry": "Erneut versuchen",
    ]
]
