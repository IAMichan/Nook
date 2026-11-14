import Foundation

// Texts for what Nook brings to your attention by himself: quiet hours shared by the Mac and the phone, follow-up
// reminders and scheduled messages in chats, and the rows Today ranks (a reply you owe, a birthday).

let attentionTranslations: [AppLanguage: [String: String]] = [
    .nl: [
        "chats.scheduled.late": "Dit bericht had al weg moeten gaan terwijl je Mac sliep. Nu versturen?",
        "chats.scheduled.gone": "Een gepland bericht kon niet weg: de chat is er niet meer.",
        "app.today.owed": "%@ wacht op je antwoord",
        "app.today.reply": "Antwoorden",
        "app.today.birthday": "%@ is vandaag jarig",
        "menu.needsYou": "Wacht op jou: %@",
        "notices.quietHours.title": "Stille uren",
        "notices.quietHours.detail": "Tussen deze uren geen pop-ups, geluiden of meldingen op je telefoon. Alles komt wel in de lijst.",
        "companion.push.quietShared": "Stille uren stel je in bij Instellingen › Meldingen. Ze gelden ook voor je telefoon.",
    ],
    .en: [
        "chats.scheduled.late": "This message was due while your Mac was asleep. Send it now?",
        "chats.scheduled.gone": "A scheduled message could not go: the chat is no longer there.",
        "app.today.owed": "%@ is waiting for your reply",
        "app.today.reply": "Reply",
        "app.today.birthday": "It's %@'s birthday today",
        "menu.needsYou": "Needs you: %@",
        "notices.quietHours.title": "Quiet hours",
        "notices.quietHours.detail": "No pop-ups, sounds or phone notifications between these hours. Everything still goes into the list.",
        "companion.push.quietShared": "Quiet hours are set in Settings › Notifications. They apply to your phone too.",
    ],
    .de: [
        "chats.scheduled.late": "Diese Nachricht war fällig, während dein Mac schlief. Jetzt senden?",
        "chats.scheduled.gone": "Eine geplante Nachricht konnte nicht gesendet werden: Den Chat gibt es nicht mehr.",
        "app.today.owed": "%@ wartet auf deine Antwort",
        "app.today.reply": "Antworten",
        "app.today.birthday": "%@ hat heute Geburtstag",
        "menu.needsYou": "Wartet auf dich: %@",
        "notices.quietHours.title": "Ruhezeiten",
        "notices.quietHours.detail": "Zwischen diesen Uhrzeiten keine Pop-ups, Töne oder Mitteilungen auf dem Telefon. Alles landet trotzdem in der Liste.",
        "companion.push.quietShared": "Ruhezeiten legst du unter Einstellungen › Mitteilungen fest. Sie gelten auch für dein Telefon.",
    ],
    .fr: [
        "chats.scheduled.late": "Ce message devait partir pendant que ton Mac dormait. L’envoyer maintenant ?",
        "chats.scheduled.gone": "Un message programmé n’a pas pu partir : la discussion n’existe plus.",
        "app.today.owed": "%@ attend ta réponse",
        "app.today.reply": "Répondre",
        "app.today.birthday": "C’est l’anniversaire de %@ aujourd’hui",
        "menu.needsYou": "T’attend : %@",
        "notices.quietHours.title": "Heures calmes",
        "notices.quietHours.detail": "Aucune fenêtre, aucun son ni notification sur le téléphone entre ces heures. Tout arrive quand même dans la liste.",
        "companion.push.quietShared": "Les heures calmes se règlent dans Réglages › Notifications. Elles valent aussi pour ton téléphone.",
    ],
    .es: [
        "chats.scheduled.late": "Este mensaje debía salir mientras tu Mac dormía. ¿Enviarlo ahora?",
        "chats.scheduled.gone": "Un mensaje programado no pudo salir: el chat ya no existe.",
        "app.today.owed": "%@ espera tu respuesta",
        "app.today.reply": "Responder",
        "app.today.birthday": "Hoy es el cumpleaños de %@",
        "menu.needsYou": "Te espera: %@",
        "notices.quietHours.title": "Horas de silencio",
        "notices.quietHours.detail": "Sin ventanas, sonidos ni avisos en el teléfono entre estas horas. Todo llega igualmente a la lista.",
        "companion.push.quietShared": "Las horas de silencio se ajustan en Ajustes › Notificaciones. También valen para tu teléfono.",
    ],
]
