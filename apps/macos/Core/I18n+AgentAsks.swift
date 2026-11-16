import Foundation

// Texts for what agents ask and say while they work: why an agent asks permission (`PermissionAsk`), an MCP server's
// question Nook declines (`ClaudeElicitation`, ACP `elicitation/create`), and stopping one subagent
// (`WorkspaceManager.stopSubagent`).

let agentAsksTranslations: [AppLanguage: [String: String]] = [
    .en: [
        "ws.approval.agentReason": "%@ says: %@",
        "ws.elicitation.declined": "%@ asked for details Nook cannot fill in yet; declined.",
        "ws.subagents.stop": "Stop this subagent",
        "ws.subagents.stopping": "Stopping subagent “%@”…",
        "ws.subagents.stopFailed": "Could not stop subagent “%@”: %@",
    ],
    .nl: [
        "ws.approval.agentReason": "%@ zegt: %@",
        "ws.elicitation.declined": "%@ vroeg om gegevens die Nook nog niet kan invullen; afgewezen.",
        "ws.subagents.stop": "Deze subagent stoppen",
        "ws.subagents.stopping": "Subagent “%@” wordt gestopt…",
        "ws.subagents.stopFailed": "Kon subagent “%@” niet stoppen: %@",
    ],
    .de: [
        "ws.approval.agentReason": "%@ sagt: %@",
        "ws.elicitation.declined": "%@ fragte nach Angaben, die Nook noch nicht ausfüllen kann; abgelehnt.",
        "ws.subagents.stop": "Diesen Subagenten stoppen",
        "ws.subagents.stopping": "Subagent „%@“ wird gestoppt…",
        "ws.subagents.stopFailed": "Subagent „%@“ konnte nicht gestoppt werden: %@",
    ],
    .fr: [
        "ws.approval.agentReason": "%@ indique : %@",
        "ws.elicitation.declined": "%@ a demandé des informations que Nook ne sait pas encore remplir ; refusé.",
        "ws.subagents.stop": "Arrêter ce sous-agent",
        "ws.subagents.stopping": "Arrêt du sous-agent « %@ »…",
        "ws.subagents.stopFailed": "Impossible d'arrêter le sous-agent « %@ » : %@",
    ],
    .es: [
        "ws.approval.agentReason": "%@ dice: %@",
        "ws.elicitation.declined": "%@ pidió datos que Nook aún no puede rellenar; rechazado.",
        "ws.subagents.stop": "Detener este subagente",
        "ws.subagents.stopping": "Deteniendo el subagente «%@»…",
        "ws.subagents.stopFailed": "No se pudo detener el subagente «%@»: %@",
    ],
]
