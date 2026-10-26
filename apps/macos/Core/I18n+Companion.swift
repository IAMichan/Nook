import Foundation

// Texts of the iPhone companion in Settings › Devices: versions of a paired phone, what it may do, testing the relay
// and copying diagnostics (docs/COMPANION.md).

let companionTranslations: [AppLanguage: [String: String]] = [
    .nl: [
        "companion.device.version": "app %@",
        "companion.device.outdated": "De app op deze iPhone is te oud voor deze Nook: werk Nook Companion bij op de iPhone.",
    ],
    .en: [
        "companion.device.version": "app %@",
        "companion.device.outdated": "The app on this iPhone is too old for this Nook: update Nook Companion on the iPhone.",
    ],
    .de: [
        "companion.device.version": "App %@",
        "companion.device.outdated": "Die App auf diesem iPhone ist zu alt für dieses Nook: Aktualisiere Nook Companion auf dem iPhone.",
    ],
    .fr: [
        "companion.device.version": "app %@",
        "companion.device.outdated": "L’app de cet iPhone est trop ancienne pour ce Nook : mets à jour Nook Companion sur l’iPhone.",
    ],
    .es: [
        "companion.device.version": "app %@",
        "companion.device.outdated": "La app de este iPhone es demasiado antigua para este Nook: actualiza Nook Companion en el iPhone.",
    ],
]
