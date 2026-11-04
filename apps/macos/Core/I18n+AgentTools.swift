import Foundation

// Texts for files in answers to an agent's question and the bridge's session tools.

let agentToolsTranslations: [AppLanguage: [String: String]] = [
    .nl: [
        "ws.question.attach": "Bestand toevoegen",
        "ws.question.attachHelp": "Voeg bestanden of afbeeldingen toe aan je antwoord (of plak of sleep ze hierheen); de agent krijgt hun paden",
        "ws.question.answeredBy": "Beantwoord door %@",
        "bridge.approval.organize": "%@ wil de sessie “%@” in je lijst aanpassen",
        "bridge.approval.organizeNote": "Alleen je Agents-lijst verandert; de sessie zelf gaat door zoals ze was.",
        "bridge.approval.answer": "%@ wil een vraag van de sessie “%@” beantwoorden",
        "bridge.approval.answerNote": "Het antwoord gaat naar die sessie alsof jij het gaf.",
    ],
    .en: [
        "ws.question.attach": "Attach a file",
        "ws.question.attachHelp": "Attach files or pictures to your answer (or paste or drop them here); the agent gets their paths",
        "ws.question.answeredBy": "Answered by %@",
        "bridge.approval.organize": "%@ wants to change the session “%@” in your list",
        "bridge.approval.organizeNote": "Only your Agents list changes; the session itself goes on as it was.",
        "bridge.approval.answer": "%@ wants to answer a question of the session “%@”",
        "bridge.approval.answerNote": "The answer goes to that session as if you had given it.",
    ],
    .de: [
        "ws.question.attach": "Datei anhängen",
        "ws.question.attachHelp": "Dateien oder Bilder an deine Antwort anhängen (oder hier einfügen oder ablegen); der Agent bekommt ihre Pfade",
        "ws.question.answeredBy": "Beantwortet von %@",
        "bridge.approval.organize": "%@ möchte die Sitzung „%@“ in deiner Liste ändern",
        "bridge.approval.organizeNote": "Nur deine Agents-Liste ändert sich; die Sitzung selbst läuft weiter wie zuvor.",
        "bridge.approval.answer": "%@ möchte eine Frage der Sitzung „%@“ beantworten",
        "bridge.approval.answerNote": "Die Antwort geht an diese Sitzung, als hättest du sie gegeben.",
    ],
    .fr: [
        "ws.question.attach": "Joindre un fichier",
        "ws.question.attachHelp": "Joignez des fichiers ou des images à votre réponse (ou collez-les ou déposez-les ici) ; l’agent reçoit leurs chemins",
        "ws.question.answeredBy": "Répondu par %@",
        "bridge.approval.organize": "%@ veut modifier la session « %@ » dans votre liste",
        "bridge.approval.organizeNote": "Seule votre liste Agents change ; la session elle-même continue comme avant.",
        "bridge.approval.answer": "%@ veut répondre à une question de la session « %@ »",
        "bridge.approval.answerNote": "La réponse part vers cette session comme si vous l’aviez donnée.",
    ],
    .es: [
        "ws.question.attach": "Adjuntar un archivo",
        "ws.question.attachHelp": "Adjunta archivos o imágenes a tu respuesta (o pégalos o suéltalos aquí); el agente recibe sus rutas",
        "ws.question.answeredBy": "Respondida por %@",
        "bridge.approval.organize": "%@ quiere cambiar la sesión “%@” en tu lista",
        "bridge.approval.organizeNote": "Solo cambia tu lista de Agents; la sesión sigue como estaba.",
        "bridge.approval.answer": "%@ quiere responder una pregunta de la sesión “%@”",
        "bridge.approval.answerNote": "La respuesta va a esa sesión como si la hubieras dado tú.",
    ],
]
