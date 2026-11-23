// German, French, and Spanish translations for Wave 8 (AG-80, AG-110, AG-111, AG-70).
import type { Table } from "./catalog";

export const table: Table = {
  "Could not switch account": {
    de: "Konto konnte nicht gewechselt werden",
    fr: "Impossible de changer de compte",
    es: "No se pudo cambiar de cuenta",
  },
  "Snoozed until the limit resets": {
    de: "Zurückgestellt, bis das Limit zurückgesetzt wird",
    fr: "Mis en veille jusqu’à la réinitialisation de la limite",
    es: "Pospuesto hasta que se restablezca el límite",
  },
  "Switch this session to {account} and continue immediately.": {
    de: "Diese Sitzung zu {account} wechseln und sofort fortfahren.",
    fr: "Basculer cette session sur {account} et continuer immédiatement.",
    es: "Cambiar esta sesión a {account} y continuar de inmediato.",
  },
  "Continue with {account}": {
    de: "Weiter mit {account}",
    fr: "Continuer avec {account}",
    es: "Continuar con {account}",
  },
  "Hide this session from the inbox until the usage limit resets.": {
    de: "Diese Sitzung bis zum Zurücksetzen des Nutzungslimits aus dem Posteingang ausblenden.",
    fr: "Masquer cette session de la boîte de réception jusqu’à la réinitialisation de la limite d’utilisation.",
    es: "Ocultar esta sesión de la bandeja de entrada hasta que se restablezca el límite de uso.",
  },
  "Snooze until reset": {
    de: "Bis Reset zurückstellen",
    fr: "Mettre en veille jusqu’au reset",
    es: "Posponer hasta el reinicio",
  },
  "Title updated": {
    de: "Titel aktualisiert",
    fr: "Titre mis à jour",
    es: "Título actualizado",
  },
  "Could not regenerate title": {
    de: "Titel konnte nicht neu generiert werden",
    fr: "Impossible de régénérer le titre",
    es: "No se pudo regenerar el título",
  },
  "Regenerate title": {
    de: "Titel neu generieren",
    fr: "Régénérer le titre",
    es: "Regenerar título",
  },
  "Working…": {
    de: "Arbeitet…",
    fr: "En cours…",
    es: "Trabajando…",
  },
  "Press Tab to accept or Esc to dismiss": {
    de: "Tab zum Übernehmen oder Esc zum Verwerfen drücken",
    fr: "Appuyez sur Tab pour accepter ou sur Échap pour ignorer",
    es: "Pulsa Tab para aceptar o Esc para descartar",
  },
  "Suggest the next prompt": {
    de: "Nächsten Prompt vorschlagen",
    fr: "Suggérer le prochain prompt",
    es: "Sugerir el siguiente prompt",
  },
  "Suggests a follow-up prompt in the empty composer after the agent replies (Tab accepts, Esc dismisses).": {
    de: "Schlägt nach einer Antwort des Agenten im leeren Eingabefeld eine Folgenachricht vor (Tab übernimmt, Esc verwirft).",
    fr: "Suggère un message de suivi dans le champ vide après la réponse de l’agent (Tab accepte, Échap ignore).",
    es: "Sugiere un mensaje de seguimiento en el campo vacío después de que el agente responda (Tab acepta, Esc descarta).",
  },
  "Text generation": {
    de: "Texterstellung",
    fr: "Génération de texte",
    es: "Generación de texto",
  },
  "Automatic": {
    de: "Automatisch",
    fr: "Automatique",
    es: "Automático",
  },
  "Generate session titles with": {
    de: "Sitzungstitel erstellen mit",
    fr: "Générer les titres de session avec",
    es: "Generar títulos de sesión con",
  },
  "Automatic (fastest model)": {
    de: "Automatisch (schnellstes Modell)",
    fr: "Automatique (modèle le plus rapide)",
    es: "Automático (modelo más rápido)",
  },
  "Generate commit and PR text with": {
    de: "Commit- und PR-Text erstellen mit",
    fr: "Générer le texte de commit et de PR avec",
    es: "Generar texto de commit y PR con",
  },
  "Suggest next prompt with": {
    de: "Nächsten Prompt vorschlagen mit",
    fr: "Suggérer le prochain prompt avec",
    es: "Sugerir el siguiente prompt con",
  },
  "Settle when pull request is merged": {
    de: "Erledigen, sobald der Pull Request zusammengeführt wurde",
    fr: "Classer lorsque la pull request est fusionnée",
    es: "Resolver cuando la pull request se fusione",
  },
  "Settle when pull request is closed": {
    de: "Erledigen, sobald der Pull Request geschlossen wurde",
    fr: "Classer lorsque la pull request est fermée",
    es: "Resolver cuando la pull request se cierre",
  },
  "Keep in inbox while pull request is open": {
    de: "Im Posteingang behalten, solange ein Pull Request offen ist",
    fr: "Garder dans la boîte de réception tant qu’une pull request est ouverte",
    es: "Mantener en la bandeja mientras la pull request esté abierta",
  },
  "Stop dev servers when settling": {
    de: "Dev-Server beim Erledigen stoppen",
    fr: "Arrêter les serveurs de dév lors du classement",
    es: "Detener servidores de desarrollo al resolver",
  },
  "Stops local dev servers in the session's folder when the last unsettled session in that folder settles.": {
    de: "Stoppt lokale Dev-Server im Ordner der Sitzung, sobald die letzte offene Sitzung in diesem Ordner erledigt wird.",
    fr: "Arrête les serveurs de développement locaux dans le dossier de la session lorsque la dernière session active de ce dossier est classée.",
    es: "Detiene los servidores de desarrollo locales en la carpeta de la sesión cuando se resuelve la última sesión abierta en esa carpeta.",
  },
  "Close idle terminals when settling": {
    de: "Inaktive Terminals beim Erledigen schließen",
    fr: "Fermer les terminaux inactifs lors du classement",
    es: "Cerrar terminales inactivas al resolver",
  },
  "Run command when settling": {
    de: "Befehl beim Erledigen ausführen",
    fr: "Exécuter une commande lors du classement",
    es: "Ejecutar comando al resolver",
  },
  "Runs in the session's working folder when the last unsettled session there settles.": {
    de: "Wird im Arbeitsordner der Sitzung ausgeführt, sobald die letzte offene Sitzung dort erledigt wird.",
    fr: "S’exécute dans le dossier de travail de la session lorsque la dernière session ouverte y est classée.",
    es: "Se ejecuta en la carpeta de trabajo de la sesión cuando se resuelve la última sesión abierta allí.",
  },
  "e.g. docker compose stop": {
    de: "z. B. docker compose stop",
    fr: "p. ex. docker compose stop",
    es: "p. ej. docker compose stop",
  },
};
