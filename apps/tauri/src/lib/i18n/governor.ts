import type { Table } from "./catalog";

// AgentGovernor / ResourceWaitStrip strings (AG-76, ported from `apps/macos/Core/I18n+Energy.swift`).
export const table: Table = {
  "This agent's commands are waiting": {
    de: "Die Befehle dieses Agenten warten kurz",
    fr: "Les commandes de cet agent patientent",
    es: "Los comandos de este agente esperan",
  },
  "Your computer is short on memory. They go on as soon as there is room, in two minutes at most.": {
    de: "Dein Computer hat wenig freien Speicher. Sie laufen weiter, sobald Platz ist, spätestens in zwei Minuten.",
    fr: "Votre ordinateur manque de mémoire. Elles reprennent dès qu'il y a de la place, dans deux minutes au plus.",
    es: "Tu ordenador tiene poca memoria libre. Siguen en cuanto haya espacio, como mucho en dos minutos.",
  },
  "Let them go on": {
    de: "Weiterlaufen lassen",
    fr: "Laisser continuer",
    es: "Dejar que sigan",
  },
};
