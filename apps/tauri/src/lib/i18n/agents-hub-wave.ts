// Translations for AG-41 (compaction indicator), AG-42 (approval audit log), AG-45 (granted rules per project),
// and AG-112 (bulk delete, custom snooze sheet, dropping files onto session rows).
import type { Table } from "./catalog";

export const table: Table = {
  "Compacting the conversation…": {
    de: "Gespräch wird zusammengefasst…",
    fr: "Compactage de la conversation…",
    es: "Compactando la conversación…",
  },
  "Compacting…": {
    de: "Zusammenfassen…",
    fr: "Compactage…",
    es: "Compactando…",
  },
  "Permissions": {
    de: "Berechtigungen",
    fr: "Autorisations",
    es: "Permisos",
  },
  "Granted rules": {
    de: "Erteilte Regeln",
    fr: "Règles accordées",
    es: "Reglas concedidas",
  },
  "Granted rules…": {
    de: "Erteilte Regeln…",
    fr: "Règles accordées…",
    es: "Reglas concedidas…",
  },
  "Granted rules and approval log": {
    de: "Erteilte Regeln und Genehmigungsverlauf",
    fr: "Règles accordées et journal des autorisations",
    es: "Reglas concedidas y registro de aprobaciones",
  },
  "Approval log": {
    de: "Genehmigungsverlauf",
    fr: "Journal des autorisations",
    es: "Registro de aprobaciones",
  },
  "Approval log…": {
    de: "Genehmigungsverlauf…",
    fr: "Journal des autorisations…",
    es: "Registro de aprobaciones…",
  },
  "Filter rules or projects…": {
    de: "Regeln oder Projekte filtern…",
    fr: "Filtrer les règles ou les projets…",
    es: "Filtrar reglas o proyectos…",
  },
  "All projects": {
    de: "Alle Projekte",
    fr: "Tous les projets",
    es: "Todos los proyectos",
  },
  "All projects (user)": {
    de: "Alle Projekte (Benutzer)",
    fr: "Tous les projets (utilisateur)",
    es: "Todos los proyectos (usuario)",
  },
  "this project": {
    de: "dieses Projekt",
    fr: "ce projet",
    es: "este proyecto",
  },
  "shared in project": {
    de: "im Projekt geteilt",
    fr: "partagé dans le projet",
    es: "compartido en el proyecto",
  },
  "all projects": {
    de: "alle Projekte",
    fr: "tous les projets",
    es: "todos los proyectos",
  },
  "this session": {
    de: "diese Sitzung",
    fr: "cette session",
    es: "esta sesión",
  },
  "agent decides": {
    de: "Agent entscheidet",
    fr: "l'agent décide",
    es: "el agente decide",
  },
  "No granted rules yet": {
    de: "Noch keine erteilten Regeln",
    fr: "Aucune règle accordée pour l'instant",
    es: "Aún no hay reglas concedidas",
  },
  "When you choose \"Always\" on an approval request, the rule appears here by project so you can revoke it anytime.": {
    de: "Wenn du bei einer Genehmigungsanfrage „Immer“ wählst, erscheint die Regel hier pro Projekt und kann jederzeit widerrufen werden.",
    fr: "Lorsque vous choisissez « Toujours » sur une demande d'autorisation, la règle apparaît ici par projet et peut être révoquée à tout moment.",
    es: "Cuando eliges «Siempre» en una solicitud de permiso, la regla aparece aquí por proyecto para que puedas revocarla en cualquier momento.",
  },
  "Revoke": {
    de: "Widerrufen",
    fr: "Révoquer",
    es: "Revocar",
  },
  "Revoke all": {
    de: "Alle widerrufen",
    fr: "Tout révoquer",
    es: "Revocar todo",
  },
  "Rule revoked": {
    de: "Regel widerrufen",
    fr: "Règle révoquée",
    es: "Regla revocada",
  },
  "Revoke all rules for {project}?": {
    de: "Alle Regeln für {project} widerrufen?",
    fr: "Révoquer toutes les règles pour {project} ?",
    es: "¿Revocar todas las reglas de {project}?",
  },
  "Agents will ask for permission again before running these actions.": {
    de: "Agents fragen danach wieder um Erlaubnis, bevor sie diese Aktionen ausführen.",
    fr: "Les agents demanderont de nouveau l'autorisation avant d'exécuter ces actions.",
    es: "Los agentes volverán a pedir permiso antes de ejecutar estas acciones.",
  },
  "{n} rules revoked": {
    de: "{n} Regeln widerrufen",
    fr: "{n} règles révoquées",
    es: "{n} reglas revocadas",
  },
  "Search by agent, project, command, or decision…": {
    de: "Nach Agent, Projekt, Befehl oder Entscheidung suchen…",
    fr: "Rechercher par agent, projet, commande ou décision…",
    es: "Buscar por agente, proyecto, comando o decisión…",
  },
  "Search approval log": {
    de: "Genehmigungsverlauf durchsuchen",
    fr: "Rechercher dans le journal des autorisations",
    es: "Buscar en el registro de aprobaciones",
  },
  "Clear approval log?": {
    de: "Genehmigungsverlauf leeren?",
    fr: "Effacer le journal des autorisations ?",
    es: "¿Borrar el registro de aprobaciones?",
  },
  "Granted rules are not affected.": {
    de: "Erteilte Regeln bleiben erhalten.",
    fr: "Les règles accordées ne sont pas affectées.",
    es: "Las reglas concedidas no se ven afectadas.",
  },
  "Approval log cleared": {
    de: "Genehmigungsverlauf geleert",
    fr: "Journal des autorisations effacé",
    es: "Registro de aprobaciones borrado",
  },
  "Allowed": {
    de: "Erlaubt",
    fr: "Autorisé",
    es: "Permitido",
  },
  "Always": {
    de: "Immer",
    fr: "Toujours",
    es: "Siempre",
  },
  "Denied": {
    de: "Abgelehnt",
    fr: "Refusé",
    es: "Denegado",
  },
  "Terminal": {
    de: "Terminal",
    fr: "Terminal",
    es: "Terminal",
  },
  "Expired": {
    de: "Abgelaufen",
    fr: "Expiré",
    es: "Caducado",
  },
  "App": {
    de: "App",
    fr: "App",
    es: "App",
  },
  "Notification": {
    de: "Mitteilung",
    fr: "Notification",
    es: "Notificación",
  },
  "Phone": {
    de: "Telefon",
    fr: "Téléphone",
    es: "Teléfono",
  },
  "No approval decisions logged yet": {
    de: "Noch keine Genehmigungen protokolliert",
    fr: "Aucune décision d'autorisation enregistrée",
    es: "Aún no hay decisiones de permiso registradas",
  },
  "Every allow, deny, or \"Always\" decision you make in Nook is recorded here.": {
    de: "Jede Erlaubnis, Ablehnung oder „Immer“-Auswahl in Nook wird hier festgehalten.",
    fr: "Chaque autorisation, refus ou choix « Toujours » dans Nook est enregistré ici.",
    es: "Cada permiso, rechazo o elección de «Siempre» en Nook queda registrado aquí.",
  },
  "High-risk command": {
    de: "Riskanter Befehl",
    fr: "Commande à risque",
    es: "Comando de alto riesgo",
  },
  "Risk": {
    de: "Risiko",
    fr: "Risque",
    es: "Riesgo",
  },
  "Delete 1 session?": {
    de: "1 Sitzung löschen?",
    fr: "Supprimer 1 session ?",
    es: "¿Eliminar 1 sesión?",
  },
  "Delete {n} sessions?": {
    de: "{n} Sitzungen löschen?",
    fr: "Supprimer {n} sessions ?",
    es: "¿Eliminar {n} sesiones?",
  },
  "The selected sessions will be permanently removed from Nook.": {
    de: "Die ausgewählten Sitzungen werden dauerhaft aus Nook entfernt.",
    fr: "Les sessions sélectionnées seront définitivement supprimées de Nook.",
    es: "Las sesiones seleccionadas se eliminarán permanentemente de Nook.",
  },
  "Drop here": {
    de: "Hier ablegen",
    fr: "Déposer ici",
    es: "Soltar aquí",
  },
  "Pick a time…": {
    de: "Zeitpunkt wählen…",
    fr: "Choisir une heure…",
    es: "Elegir una hora…",
  },
  "Duration": {
    de: "Dauer",
    fr: "Durée",
    es: "Duración",
  },
  "Date & time": {
    de: "Datum & Uhrzeit",
    fr: "Date et heure",
    es: "Fecha y hora",
  },
  "Amount": {
    de: "Anzahl",
    fr: "Quantité",
    es: "Cantidad",
  },
  "Unit": {
    de: "Einheit",
    fr: "Unité",
    es: "Unidad",
  },
  "minutes": {
    de: "Minuten",
    fr: "minutes",
    es: "minutos",
  },
  "hours": {
    de: "Stunden",
    fr: "heures",
    es: "horas",
  },
  "days": {
    de: "Tage",
    fr: "jours",
    es: "días",
  },
  "Snoozed until {time}": {
    de: "Schlummern bis {time}",
    fr: "Reporté jusqu'à {time}",
    es: "Pospuesto hasta {time}",
  },
  "Choose a time in the future.": {
    de: "Wähle einen Zeitpunkt in der Zukunft.",
    fr: "Choisissez une heure dans le futur.",
    es: "Elige una hora en el futuro.",
  },
};
