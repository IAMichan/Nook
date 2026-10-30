import Foundation

// Texts of push through the relay (`RelayPushClient`): Settings › Connections › iPhone › push notifications.

let relayPushTranslations: [AppLanguage: [String: String]] = [
    .nl: [
        "relayPush.route": "Versturen via",
        "relayPush.route.relay": "Nooks relay",
        "relayPush.route.own": "Mijn eigen APNs-sleutel",
        "relayPush.hint": "Geen Apple-ontwikkelaarsaccount nodig. Elke melding wordt versleuteld met de sleutel van je gekoppelde iPhone; de relay en Apple zien alleen “Nook needs you”, en je iPhone toont de echte tekst.",
        "relayPush.noRelay": "Deze build heeft geen relay van Nook. Zet hierboven een eigen relay op (met Nooks APNs-geheimen), of gebruik je eigen APNs-sleutel.",
        "relayPush.liveActivities": "Live Activities hebben nog je eigen APNs-sleutel nodig.",
    ],
    .en: [
        "relayPush.route": "Send through",
        "relayPush.route.relay": "Nook's relay",
        "relayPush.route.own": "My own APNs key",
        "relayPush.hint": "No Apple developer account needed. Every notification is encrypted with your paired iPhone's key; the relay and Apple only see “Nook needs you”, and your iPhone shows the real text.",
        "relayPush.noRelay": "This build has no relay from Nook. Set up your own relay above (with Nook's APNs secrets), or use your own APNs key.",
        "relayPush.liveActivities": "Live Activities still need your own APNs key.",
    ],
    .de: [
        "relayPush.route": "Senden über",
        "relayPush.route.relay": "Nooks Relay",
        "relayPush.route.own": "Mein eigener APNs-Schlüssel",
        "relayPush.hint": "Kein Apple-Entwicklerkonto nötig. Jede Mitteilung wird mit dem Schlüssel deines gekoppelten iPhones verschlüsselt; Relay und Apple sehen nur „Nook needs you“, dein iPhone zeigt den echten Text.",
        "relayPush.noRelay": "Dieser Build hat kein Relay von Nook. Richte oben ein eigenes Relay ein (mit Nooks APNs-Secrets) oder nutze deinen eigenen APNs-Schlüssel.",
        "relayPush.liveActivities": "Live-Aktivitäten brauchen weiterhin deinen eigenen APNs-Schlüssel.",
    ],
    .fr: [
        "relayPush.route": "Envoyer via",
        "relayPush.route.relay": "Le relais de Nook",
        "relayPush.route.own": "Ma propre clé APNs",
        "relayPush.hint": "Aucun compte développeur Apple requis. Chaque notification est chiffrée avec la clé de votre iPhone jumelé ; le relais et Apple ne voient que « Nook needs you », et votre iPhone affiche le vrai texte.",
        "relayPush.noRelay": "Cette build n’a pas de relais Nook. Configurez votre propre relais ci-dessus (avec les secrets APNs de Nook), ou utilisez votre propre clé APNs.",
        "relayPush.liveActivities": "Les Activités en direct nécessitent toujours votre propre clé APNs.",
    ],
    .es: [
        "relayPush.route": "Enviar mediante",
        "relayPush.route.relay": "El relé de Nook",
        "relayPush.route.own": "Mi propia clave APNs",
        "relayPush.hint": "No necesitas cuenta de desarrollador de Apple. Cada notificación se cifra con la clave de tu iPhone vinculado; el relé y Apple solo ven «Nook needs you», y tu iPhone muestra el texto real.",
        "relayPush.noRelay": "Esta compilación no tiene relé de Nook. Configura tu propio relé arriba (con los secretos APNs de Nook) o usa tu propia clave APNs.",
        "relayPush.liveActivities": "Las Actividades en vivo siguen necesitando tu propia clave APNs.",
    ],
]
