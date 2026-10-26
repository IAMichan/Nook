import Foundation

// Texts for Settings › Workspace › the provider traffic log (see ProviderTrafficLog).

let providerTrafficTranslations: [AppLanguage: [String: String]] = [
    .nl: [
        "settings.ws.trafficLog": "Agentverkeer bewaren",
        "settings.ws.trafficLog.footer": "Bewaart per sessie wat Nook en de agent elkaar sturen (tot 4 MB per proces), om een fout na te spelen. Het bevat je prompts en de antwoorden en blijft op deze Mac, in workspace/provider-traffic; omgevingsvariabelen en sleutels worden nooit opgeslagen.",
    ],
    .en: [
        "settings.ws.trafficLog": "Keep agent traffic",
        "settings.ws.trafficLog.footer": "Keeps, per session, what Nook and the agent send each other (up to 4 MB per process), to replay a bug. It holds your prompts and the answers and stays on this Mac, in workspace/provider-traffic; environment variables and keys are never written.",
    ],
    .de: [
        "settings.ws.trafficLog": "Agent-Verkehr aufbewahren",
        "settings.ws.trafficLog.footer": "Bewahrt pro Sitzung auf, was Nook und der Agent einander senden (bis zu 4 MB pro Prozess), um einen Fehler nachzuspielen. Es enthält deine Prompts und die Antworten und bleibt auf diesem Mac, in workspace/provider-traffic; Umgebungsvariablen und Schlüssel werden nie gespeichert.",
    ],
    .fr: [
        "settings.ws.trafficLog": "Conserver le trafic des agents",
        "settings.ws.trafficLog.footer": "Conserve, par session, ce que Nook et l’agent s’envoient (jusqu’à 4 Mo par processus), pour rejouer un bug. Il contient vos prompts et les réponses et reste sur ce Mac, dans workspace/provider-traffic ; les variables d’environnement et les clés ne sont jamais enregistrées.",
    ],
    .es: [
        "settings.ws.trafficLog": "Guardar el tráfico de los agentes",
        "settings.ws.trafficLog.footer": "Guarda, por sesión, lo que Nook y el agente se envían (hasta 4 MB por proceso), para reproducir un error. Contiene tus prompts y las respuestas y se queda en este Mac, en workspace/provider-traffic; las variables de entorno y las claves nunca se guardan.",
    ],
]
