//! Automations for Nook Chat itself (`workspace::nook_schedule`, `tools::schedule`): schedules in words, the plan
//! lines, and the personal secretary's three tasks (their prompts are what Nook answers, so they follow the language).

use super::Row;

pub const ROWS: &[Row] = &[
    ("every {n} minutes", "alle {n} Minuten", "toutes les {n} minutes", "cada {n} minutos"),
    ("every day at {time}", "jeden Tag um {time}", "tous les jours à {time}", "cada día a las {time}"),
    ("every weekday at {time}", "jeden Werktag um {time}", "chaque jour ouvré à {time}", "cada día laborable a las {time}"),
    ("every {days} at {time}", "jeden {days} um {time}", "chaque {days} à {time}", "cada {days} a las {time}"),
    ("when its webhook is called", "wenn sein Webhook aufgerufen wird", "quand son webhook est appelé", "cuando se llama a su webhook"),
    ("once, on {when}", "einmal, am {when}", "une fois, le {when}", "una vez, el {when}"),
    ("Sunday", "Sonntag", "dimanche", "domingo"),
    ("Monday", "Montag", "lundi", "lunes"),
    ("Tuesday", "Dienstag", "mardi", "martes"),
    ("Wednesday", "Mittwoch", "mercredi", "miércoles"),
    ("Thursday", "Donnerstag", "jeudi", "jueves"),
    ("Friday", "Freitag", "vendredi", "viernes"),
    ("Saturday", "Samstag", "samedi", "sábado"),
    ("Automation “{title}”: {schedule}", "Automatisierung „{title}“: {schedule}", "Automatisation « {title} » : {schedule}", "Automatización «{title}»: {schedule}"),
    ("Automation (not complete yet)", "Automatisierung (noch nicht vollständig)", "Automatisation (pas encore complète)", "Automatización (aún incompleta)"),
    ("Read automations", "Automatisierungen lesen", "Lire les automatisations", "Ver automatizaciones"),
    ("Set up the personal secretary: {tasks}", "Persönliche Sekretärin einrichten: {tasks}", "Configurer le secrétaire personnel : {tasks}", "Configurar el secretario personal: {tasks}"),
    ("Change automation “{title}”", "Automatisierung „{title}“ ändern", "Modifier l’automatisation « {title} »", "Cambiar la automatización «{title}»"),
    (
        "Change automation “{title}” (not complete yet)",
        "Automatisierung „{title}“ ändern (noch nicht vollständig)",
        "Modifier l’automatisation « {title} » (pas encore complète)",
        "Cambiar la automatización «{title}» (aún incompleta)",
    ),
    ("new name “{title}”", "neuer Name „{title}“", "nouveau nom « {title} »", "nuevo nombre «{title}»"),
    ("new instructions", "neue Anweisungen", "nouvelles instructions", "nuevas instrucciones"),
    ("resume", "fortsetzen", "reprendre", "reanudar"),
    ("pause", "pausieren", "mettre en pause", "pausar"),
    ("only speak up for something new", "nur bei Neuem melden", "ne signaler que du nouveau", "avisar solo si hay algo nuevo"),
    ("always report", "immer berichten", "toujours faire un point", "informar siempre"),
    ("Morning briefing", "Morgenbriefing", "Briefing du matin", "Resumen de la mañana"),
    (
        "Give me my morning briefing across everything: mail, all my chats, my calendar today and what is coming, reminders and open loops, pull requests and agents that wait for me. Tell me what happened since yesterday, most important first, and prepare the reply or action for everything that needs me, so I only approve it or say what to change.",
        "Gib mir mein Morgenbriefing über alles: Mail, alle meine Chats, meinen Kalender heute und was kommt, Erinnerungen und offene Punkte, Pull Requests und Agenten, die auf mich warten. Sag, was seit gestern passiert ist, Wichtigstes zuerst, und bereite für alles, was mich braucht, die Antwort oder Aktion vor, sodass ich nur zustimme oder sage, was anders soll.",
        "Fais-moi mon briefing du matin sur tout : mails, toutes mes discussions, mon agenda du jour et ce qui arrive, rappels et points ouverts, pull requests et agents qui m’attendent. Dis-moi ce qui s’est passé depuis hier, le plus important d’abord, et prépare la réponse ou l’action pour tout ce qui a besoin de moi, pour que je n’aie qu’à approuver ou dire ce qu’il faut changer.",
        "Dame mi resumen de la mañana sobre todo: correo, todos mis chats, mi agenda de hoy y lo que viene, recordatorios y temas abiertos, pull requests y agentes que me esperan. Dime qué pasó desde ayer, lo más importante primero, y prepara la respuesta o la acción para todo lo que me necesita, para que solo tenga que aprobar o decir qué cambiar.",
    ),
    ("Midday check", "Mittagscheck", "Point de midi", "Revisión del mediodía"),
    (
        "Check whether anything new needs me since this morning: mail, chats, invitations or changes in my calendar, deadlines, pull requests and agents that wait. Prepare the reply or action for each one.",
        "Schau, ob es seit heute Morgen etwas Neues gibt, das mich braucht: Mail, Chats, Einladungen oder Änderungen im Kalender, Fristen, Pull Requests und wartende Agenten. Bereite für jeden Punkt die Antwort oder Aktion vor.",
        "Regarde s’il y a du nouveau depuis ce matin qui a besoin de moi : mails, discussions, invitations ou changements dans mon agenda, échéances, pull requests et agents en attente. Prépare la réponse ou l’action pour chaque point.",
        "Mira si desde esta mañana hay algo nuevo que me necesite: correo, chats, invitaciones o cambios en mi agenda, plazos, pull requests y agentes que esperan. Prepara la respuesta o la acción para cada uno.",
    ),
    ("End of day", "Tagesabschluss", "Fin de journée", "Cierre del día"),
    (
        "Wrap up my day: what is still open (unanswered mail and chats, promises, reminders, pull requests, agents), what is in my calendar tomorrow and what I should prepare. Prepare everything I can still settle now.",
        "Schließ meinen Tag ab: was noch offen ist (unbeantwortete Mails und Chats, Zusagen, Erinnerungen, Pull Requests, Agenten), was morgen im Kalender steht und was ich vorbereiten sollte. Bereite alles vor, was ich jetzt noch erledigen kann.",
        "Clôture ma journée : ce qui reste ouvert (mails et discussions sans réponse, promesses, rappels, pull requests, agents), ce qu’il y a demain dans mon agenda et ce que je dois préparer. Prépare tout ce que je peux encore régler maintenant.",
        "Cierra mi día: qué sigue abierto (correos y chats sin responder, promesas, recordatorios, pull requests, agentes), qué hay mañana en mi agenda y qué debo preparar. Prepara todo lo que aún puedo resolver ahora.",
    ),
];
