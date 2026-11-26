import Foundation

// Texts of Rewind under your messages in a session: back to before a message with the files and the conversation, the
// files only, or the conversation only.

let rewindTranslations: [AppLanguage: [String: String]] = [
    .nl: [
        "ws.rewind.menu": "Terug naar vóór dit bericht…",
        "ws.rewind.confirm": "Terug naar vóór dit bericht?",
        "ws.rewind.detail": "Kies wat teruggaat tot vóór “%@”. Bestanden en gesprek: de wijzigingen sindsdien verdwijnen en de agent vergeet dat bericht en alles daarna. Alleen bestanden: de agent onthoudt het gesprek en hoort met je volgende bericht dat de bestanden terug zijn. Alleen gesprek: de bestanden blijven zoals ze nu zijn.",
        "ws.rewind.detailFiles": "De bestanden in deze worktree gaan terug naar hoe ze waren vóór “%@”; latere wijzigingen gaan verloren. Deze agent kan zijn gesprek niet terugzetten: hij onthoudt het en hoort met je volgende bericht dat de bestanden terug zijn.",
        "ws.rewind.detailConversation": "De agent vergeet “%@” en alles daarna. De bestanden blijven zoals ze nu zijn: alleen een sessie in een eigen worktree kan ook de bestanden terugzetten.",
        "ws.rewind.everything": "Bestanden en gesprek",
        "ws.rewind.files": "Alleen bestanden",
        "ws.rewind.conversation": "Alleen gesprek",
        "ws.rewind.doneFiles": "Bestanden teruggezet naar een eerder punt. Het gesprek is gebleven; de agent hoort het met je volgende bericht.",
    ],
    .en: [
        "ws.rewind.menu": "Go back to before this message…",
        "ws.rewind.confirm": "Go back to before this message?",
        "ws.rewind.detail": "Choose what goes back to before “%@”. Files and conversation: the changes since are lost and the agent forgets that message and everything after it. Files only: the agent keeps the conversation and learns with your next message that the files went back. Conversation only: the files stay as they are now.",
        "ws.rewind.detailFiles": "The files in this worktree go back to how they were before “%@”; later changes are lost. This agent can't roll back its conversation: it keeps it and learns with your next message that the files went back.",
        "ws.rewind.detailConversation": "The agent forgets “%@” and everything after it. The files stay as they are now: only a session in its own worktree can put the files back too.",
        "ws.rewind.everything": "Files and conversation",
        "ws.rewind.files": "Files only",
        "ws.rewind.conversation": "Conversation only",
        "ws.rewind.doneFiles": "Files restored to an earlier point. The conversation stayed; the agent learns about it with your next message.",
    ],
    .de: [
        "ws.rewind.menu": "Zurück zu vor dieser Nachricht…",
        "ws.rewind.confirm": "Zurück zu vor dieser Nachricht?",
        "ws.rewind.detail": "Wähle, was auf den Stand vor „%@“ zurückgeht. Dateien und Gespräch: die Änderungen seitdem gehen verloren und der Agent vergisst diese Nachricht und alles danach. Nur Dateien: der Agent behält das Gespräch und erfährt mit deiner nächsten Nachricht, dass die Dateien zurückgesetzt sind. Nur Gespräch: die Dateien bleiben, wie sie jetzt sind.",
        "ws.rewind.detailFiles": "Die Dateien in diesem Worktree gehen auf den Stand vor „%@“ zurück; spätere Änderungen gehen verloren. Dieser Agent kann sein Gespräch nicht zurücksetzen: er behält es und erfährt mit deiner nächsten Nachricht, dass die Dateien zurückgesetzt sind.",
        "ws.rewind.detailConversation": "Der Agent vergisst „%@“ und alles danach. Die Dateien bleiben, wie sie jetzt sind: nur eine Sitzung in einem eigenen Worktree kann auch die Dateien zurücksetzen.",
        "ws.rewind.everything": "Dateien und Gespräch",
        "ws.rewind.files": "Nur Dateien",
        "ws.rewind.conversation": "Nur Gespräch",
        "ws.rewind.doneFiles": "Dateien auf einen früheren Stand zurückgesetzt. Das Gespräch ist geblieben; der Agent erfährt es mit deiner nächsten Nachricht.",
    ],
    .fr: [
        "ws.rewind.menu": "Revenir à avant ce message…",
        "ws.rewind.confirm": "Revenir à avant ce message ?",
        "ws.rewind.detail": "Choisissez ce qui revient à avant « %@ ». Fichiers et conversation : les modifications depuis sont perdues et l’agent oublie ce message et tout ce qui suit. Fichiers seulement : l’agent garde la conversation et apprend avec votre prochain message que les fichiers sont revenus. Conversation seulement : les fichiers restent tels qu’ils sont.",
        "ws.rewind.detailFiles": "Les fichiers de ce worktree reviennent à leur état d’avant « %@ » ; les modifications ultérieures sont perdues. Cet agent ne peut pas revenir en arrière dans sa conversation : il la garde et apprend avec votre prochain message que les fichiers sont revenus.",
        "ws.rewind.detailConversation": "L’agent oublie « %@ » et tout ce qui suit. Les fichiers restent tels qu’ils sont : seule une session dans son propre worktree peut aussi rétablir les fichiers.",
        "ws.rewind.everything": "Fichiers et conversation",
        "ws.rewind.files": "Fichiers seulement",
        "ws.rewind.conversation": "Conversation seulement",
        "ws.rewind.doneFiles": "Fichiers restaurés à un point antérieur. La conversation est restée ; l’agent l’apprend avec votre prochain message.",
    ],
    .es: [
        "ws.rewind.menu": "Volver a antes de este mensaje…",
        "ws.rewind.confirm": "¿Volver a antes de este mensaje?",
        "ws.rewind.detail": "Elige qué vuelve a antes de «%@». Archivos y conversación: los cambios desde entonces se pierden y el agente olvida ese mensaje y todo lo posterior. Solo archivos: el agente conserva la conversación y sabrá con tu próximo mensaje que los archivos volvieron. Solo conversación: los archivos se quedan como están.",
        "ws.rewind.detailFiles": "Los archivos de este worktree vuelven a como estaban antes de «%@»; los cambios posteriores se pierden. Este agente no puede volver atrás en su conversación: la conserva y sabrá con tu próximo mensaje que los archivos volvieron.",
        "ws.rewind.detailConversation": "El agente olvida «%@» y todo lo posterior. Los archivos se quedan como están: solo una sesión en su propio worktree puede restaurar también los archivos.",
        "ws.rewind.everything": "Archivos y conversación",
        "ws.rewind.files": "Solo archivos",
        "ws.rewind.conversation": "Solo conversación",
        "ws.rewind.doneFiles": "Archivos restaurados a un punto anterior. La conversación se mantuvo; el agente lo sabrá con tu próximo mensaje.",
    ],
]
