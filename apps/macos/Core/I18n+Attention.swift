import Foundation

// Texts for what Nook brings to your attention by himself: quiet hours shared by the Mac and the phone, follow-up
// reminders and scheduled messages in chats, and the rows Today ranks (a reply you owe, a birthday).

let attentionTranslations: [AppLanguage: [String: String]] = [
    .nl: [
        "notices.quietHours.title": "Stille uren",
        "notices.quietHours.detail": "Tussen deze uren geen pop-ups, geluiden of meldingen op je telefoon. Alles komt wel in de lijst.",
        "companion.push.quietShared": "Stille uren stel je in bij Instellingen › Meldingen. Ze gelden ook voor je telefoon.",
    ],
    .en: [
        "notices.quietHours.title": "Quiet hours",
        "notices.quietHours.detail": "No pop-ups, sounds or phone notifications between these hours. Everything still goes into the list.",
        "companion.push.quietShared": "Quiet hours are set in Settings › Notifications. They apply to your phone too.",
    ],
    .de: [
        "notices.quietHours.title": "Ruhezeiten",
        "notices.quietHours.detail": "Zwischen diesen Uhrzeiten keine Pop-ups, Töne oder Mitteilungen auf dem Telefon. Alles landet trotzdem in der Liste.",
        "companion.push.quietShared": "Ruhezeiten legst du unter Einstellungen › Mitteilungen fest. Sie gelten auch für dein Telefon.",
    ],
    .fr: [
        "notices.quietHours.title": "Heures calmes",
        "notices.quietHours.detail": "Aucune fenêtre, aucun son ni notification sur le téléphone entre ces heures. Tout arrive quand même dans la liste.",
        "companion.push.quietShared": "Les heures calmes se règlent dans Réglages › Notifications. Elles valent aussi pour ton téléphone.",
    ],
    .es: [
        "notices.quietHours.title": "Horas de silencio",
        "notices.quietHours.detail": "Sin ventanas, sonidos ni avisos en el teléfono entre estas horas. Todo llega igualmente a la lista.",
        "companion.push.quietShared": "Las horas de silencio se ajustan en Ajustes › Notificaciones. También valen para tu teléfono.",
    ],
]
