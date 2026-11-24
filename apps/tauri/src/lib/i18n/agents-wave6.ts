// German, French, and Spanish for Agents wave 6 (AG-75 session concurrency cap & AG-61 /btw, /side side chats).
import type { Table } from "./catalog";

export const table: Table = {
  // Session concurrency cap (AG-75, matching macOS `settings.ws.maxWorking.*`)
  "Sessions working at once": {
    de: "Gleichzeitig arbeitende Sitzungen",
    fr: "Sessions actives en même temps",
    es: "Sesiones trabajando a la vez",
  },
  "At most this many sessions work at the same time; a new turn past it waits and starts as soon as another session's turn ends.": {
    de: "Höchstens so viele Sitzungen arbeiten gleichzeitig; ein neuer Durchgang darüber wartet und startet, sobald der Durchgang einer anderen Sitzung endet.",
    fr: "Au plus ce nombre de sessions travaillent en même temps ; un nouveau tour au-delà attend et démarre dès que le tour d'une autre session se termine.",
    es: "Como mucho trabajan a la vez estas sesiones; un turno nuevo por encima espera y empieza en cuanto termina el turno de otra sesión.",
  },
  "No limit": {
    de: "Keine Grenze",
    fr: "Aucune limite",
    es: "Sin límite",
  },

  // Side chat (`/btw`, `/side`, AG-61)
  "Side chat": {
    de: "Nebengespräch",
    fr: "Aparté",
    es: "Chat lateral",
  },
  "Ask a quick side question without interrupting the agent": {
    de: "Stelle eine kurze Nebenfrage, ohne den Agenten zu unterbrechen",
    fr: "Pose une question rapide en aparté sans interrompre l'agent",
    es: "Haz una pregunta rápida aparte sin interrumpir al agente",
  },
  "Type your question after /btw or /side.": {
    de: "Tippe deine Frage nach /btw oder /side.",
    fr: "Saisis ta question après /btw ou /side.",
    es: "Escribe tu pregunta después de /btw o /side.",
  },
  "Answering…": {
    de: "Antwortet…",
    fr: "Réponse en cours…",
    es: "Respondiendo…",
  },
  "Answer copied": {
    de: "Antwort kopiert",
    fr: "Réponse copiée",
    es: "Respuesta copiada",
  },
  "Could not copy the answer": {
    de: "Konnte die Antwort nicht kopieren",
    fr: "Impossible de copier la réponse",
    es: "No se pudo copiar la respuesta",
  },
  "Copy answer": {
    de: "Antwort kopieren",
    fr: "Copier la réponse",
    es: "Copiar respuesta",
  },
  "Dismiss side chat": {
    de: "Nebengespräch schließen",
    fr: "Fermer l'aparté",
    es: "Cerrar chat lateral",
  },
};
