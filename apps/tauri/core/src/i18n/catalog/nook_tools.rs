//! Nook's own tools for coding agents (`nook_tools`, `nook_use`, `nook_chat_*`, `take_over_screen`) and agent
//! sessions as tools for Nook Chat.

use super::Row;

pub const ROWS: &[Row] = &[
    ("Nook's apps and connectors", "Nooks Apps und Verbindungen", "Apps et connexions de Nook", "Apps y conexiones de Nook"),
    ("Nook Chat conversations", "Unterhaltungen in Nook Chat", "Conversations Nook Chat", "Conversaciones de Nook Chat"),
    ("Read Nook Chat", "Nook Chat lesen", "Lire Nook Chat", "Leer Nook Chat"),
    ("Write in Nook Chat", "In Nook Chat schreiben", "Écrire dans Nook Chat", "Escribir en Nook Chat"),
    ("Take over screen", "Bildschirm übernehmen", "Prendre le contrôle de l'écran", "Tomar el control de la pantalla"),
    (
        "Give the task for the agent.",
        "Gib die Aufgabe für den Agenten an.",
        "Indique la tâche pour l'agent.",
        "Indica la tarea para el agente.",
    ),
    ("Unknown agent \"{name}\".", "Unbekannter Agent „{name}“.", "Agent inconnu « {name} ».", "Agente desconocido «{name}»."),
    (
        "Agents start only in a project folder the user worked in before: {folders}",
        "Agenten starten nur in einem Projektordner, in dem du schon gearbeitet hast: {folders}",
        "Les agents ne démarrent que dans un dossier de projet où tu as déjà travaillé : {folders}",
        "Los agentes solo empiezan en una carpeta de proyecto en la que ya trabajaste: {folders}",
    ),
    (
        "{agent} is not installed or signed in on this computer.",
        "{agent} ist auf diesem Computer nicht installiert oder nicht angemeldet.",
        "{agent} n'est pas installé ou connecté sur cet ordinateur.",
        "{agent} no está instalado o no ha iniciado sesión en este ordenador.",
    ),
    (
        "base is not a branch name: {base}",
        "base ist kein Branch-Name: {base}",
        "base n'est pas un nom de branche : {base}",
        "base no es un nombre de rama: {base}",
    ),
    (
        "{agent} wants to do something with Nook",
        "{agent} möchte etwas mit Nook tun",
        "{agent} veut faire quelque chose avec Nook",
        "{agent} quiere hacer algo con Nook",
    ),
    (
        "It happens in your own apps and connections, exactly as shown here.",
        "Es passiert in deinen eigenen Apps und Verbindungen, genau wie hier gezeigt.",
        "Cela se passe dans tes propres apps et connexions, exactement comme indiqué ici.",
        "Ocurre en tus propias apps y conexiones, exactamente como se muestra aquí.",
    ),
    (
        "{agent} wants to ask something in Nook Chat",
        "{agent} möchte in Nook Chat etwas fragen",
        "{agent} veut demander quelque chose dans Nook Chat",
        "{agent} quiere preguntar algo en Nook Chat",
    ),
    (
        "Nook answers with your own sources; anything Nook proposes to do still waits for you.",
        "Nook antwortet mit deinen eigenen Quellen; was Nook vorschlägt, wartet danach noch auf dich.",
        "Nook répond avec tes propres sources ; ce que Nook propose de faire attend encore ton accord.",
        "Nook responde con tus propias fuentes; lo que Nook proponga hacer sigue esperándote.",
    ),
    (
        "For {minutes} minutes, read-only: Nook does not click or type for agents.",
        "{minutes} Minuten lang, nur lesen: Nook klickt und tippt nicht für Agenten.",
        "Pendant {minutes} minutes, en lecture seule : Nook ne clique ni ne tape pour les agents.",
        "Durante {minutes} minutos, solo lectura: Nook no hace clic ni escribe por los agentes.",
    ),
    (
        "{agent} wants to read your screen",
        "{agent} möchte deinen Bildschirm lesen",
        "{agent} veut lire ton écran",
        "{agent} quiere leer tu pantalla",
    ),
    ("Agent sessions", "Agentensitzungen", "Sessions d'agents", "Sesiones de agentes"),
    ("Message agent session", "Nachricht an Agentensitzung", "Message à la session d'agent", "Mensaje a la sesión de agente"),
    ("Start agent session", "Agentensitzung starten", "Démarrer une session d'agent", "Iniciar sesión de agente"),
    (
        "No such session. Use an id from list_agent_sessions.",
        "Diese Sitzung gibt es nicht. Nimm eine ID aus list_agent_sessions.",
        "Cette session n'existe pas. Utilise un id de list_agent_sessions.",
        "Esa sesión no existe. Usa un id de list_agent_sessions.",
    ),
    (
        "Give the message for the agent.",
        "Gib die Nachricht für den Agenten an.",
        "Indique le message pour l'agent.",
        "Indica el mensaje para el agente.",
    ),
    (
        "Queued for {title}: it gets it after its current turn",
        "Für {title} eingereiht: nach der aktuellen Runde",
        "En file pour {title} : après son tour en cours",
        "En cola para {title}: después de su turno actual",
    ),
    ("Sent to {title}", "An {title} gesendet", "Envoyé à {title}", "Enviado a {title}"),
    (
        "Taken into {title}'s running turn",
        "In die laufende Runde von {title} aufgenommen",
        "Intégré au tour en cours de {title}",
        "Incluido en el turno en curso de {title}",
    ),
    (
        "Unknown mode \"{mode}\": queue or steer.",
        "Unbekannter Modus „{mode}“: queue oder steer.",
        "Mode inconnu « {mode} » : queue ou steer.",
        "Modo desconocido «{mode}»: queue o steer.",
    ),
    ("Started from Nook Chat", "Aus Nook Chat gestartet", "Démarré depuis Nook Chat", "Iniciado desde Nook Chat"),
    (
        "Started {agent} in {folder} | session id {id}",
        "{agent} in {folder} gestartet | Sitzungs-ID {id}",
        "{agent} démarré dans {folder} | id de session {id}",
        "{agent} iniciado en {folder} | id de sesión {id}",
    ),
];
