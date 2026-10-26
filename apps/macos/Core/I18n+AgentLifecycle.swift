import Foundation

// Texts for the agent lifecycle: going back to before a message (files and conversation), continuing after a restart,
// steering an agent without native steering, and cleaning up worktrees.

let agentLifecycleTranslations: [AppLanguage: [String: String]] = [
    .nl: [
        "ws.steer.restart": "Deze agent kan tijdens een beurt geen bericht aannemen: Nook onderbreekt hem en stuurt je bericht als volgende opdracht.",
        "ws.revert.detailConversation": "De bestanden in deze worktree gaan terug naar hoe ze waren vóór “%@”, en de agent vergeet dat bericht en alles daarna. Latere wijzigingen gaan verloren.",
        "ws.revert.doneConversation": "Bestanden en gesprek teruggezet naar een eerder punt. De agent weet niets meer van de latere berichten.",
        "ws.revert.conversationFailed": "Het gesprek van de agent kon niet worden teruggezet: %@",
        "ws.revert.conversationExec": "Codex draait via codex exec, dat zijn gesprek niet kan terugzetten.",
    ],
    .en: [
        "ws.steer.restart": "This agent cannot take a message during a turn: Nook interrupts it and sends your message as the next prompt.",
        "ws.revert.detailConversation": "The files in this worktree go back to how they were before “%@”, and the agent forgets that message and everything after it. Later changes are lost.",
        "ws.revert.doneConversation": "Files and conversation restored to an earlier point. The agent no longer remembers the later messages.",
        "ws.revert.conversationFailed": "The agent's conversation could not be rolled back: %@",
        "ws.revert.conversationExec": "Codex runs through codex exec, which cannot roll back its conversation.",
    ],
    .de: [
        "ws.steer.restart": "Dieser Agent kann während eines Durchgangs keine Nachricht annehmen: Nook unterbricht ihn und sendet deine Nachricht als nächsten Auftrag.",
        "ws.revert.detailConversation": "Die Dateien in diesem Worktree gehen auf den Stand vor „%@“ zurück, und der Agent vergisst diese Nachricht und alles danach. Spätere Änderungen gehen verloren.",
        "ws.revert.doneConversation": "Dateien und Gespräch auf einen früheren Stand zurückgesetzt. Der Agent erinnert sich nicht mehr an die späteren Nachrichten.",
        "ws.revert.conversationFailed": "Das Gespräch des Agenten konnte nicht zurückgesetzt werden: %@",
        "ws.revert.conversationExec": "Codex läuft über codex exec, das sein Gespräch nicht zurücksetzen kann.",
    ],
    .fr: [
        "ws.steer.restart": "Cet agent ne peut pas recevoir de message pendant un tour : Nook l'interrompt et envoie votre message comme prochaine consigne.",
        "ws.revert.detailConversation": "Les fichiers de ce worktree reviennent à leur état d'avant « %@ », et l'agent oublie ce message et tout ce qui suit. Les modifications ultérieures sont perdues.",
        "ws.revert.doneConversation": "Fichiers et conversation restaurés à un point antérieur. L'agent ne se souvient plus des messages suivants.",
        "ws.revert.conversationFailed": "La conversation de l'agent n'a pas pu être restaurée : %@",
        "ws.revert.conversationExec": "Codex passe par codex exec, qui ne peut pas restaurer sa conversation.",
    ],
    .es: [
        "ws.steer.restart": "Este agente no puede recibir mensajes durante un turno: Nook lo interrumpe y envía tu mensaje como la siguiente instrucción.",
        "ws.revert.detailConversation": "Los archivos de este worktree vuelven a como estaban antes de “%@”, y el agente olvida ese mensaje y todo lo posterior. Los cambios posteriores se pierden.",
        "ws.revert.doneConversation": "Archivos y conversación restaurados a un punto anterior. El agente ya no recuerda los mensajes posteriores.",
        "ws.revert.conversationFailed": "No se pudo restaurar la conversación del agente: %@",
        "ws.revert.conversationExec": "Codex funciona con codex exec, que no puede restaurar su conversación.",
    ],
]
