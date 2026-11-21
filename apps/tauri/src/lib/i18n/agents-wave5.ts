// German, French, and Spanish for Agents wave 5 (AG-67 /goal strip, AG-65 compaction & amber context warning, AG-66 context breakdown popover).
import type { Table } from "./catalog";

export const table: Table = {
  // Goal strip (AG-67)
  "Goal": { de: "Ziel", fr: "Objectif", es: "Objetivo" },
  "Describe this session's goal…": {
    de: "Beschreibe das Ziel dieser Sitzung…",
    fr: "Décris l'objectif de cette session…",
    es: "Describe el objetivo de esta sesión…",
  },
  "Save goal": { de: "Ziel speichern", fr: "Enregistrer l'objectif", es: "Guardar objetivo" },
  "Edit goal": { de: "Ziel bearbeiten", fr: "Modifier l'objectif", es: "Editar objetivo" },
  "Clear goal": { de: "Ziel entfernen", fr: "Effacer l'objectif", es: "Borrar objetivo" },

  // Compaction & context breakdown (AG-65, AG-66)
  "Context": { de: "Kontext", fr: "Contexte", es: "Contexto" },
  "Compacting…": { de: "Komprimiert…", fr: "Compression…", es: "Compactando…" },
  "Compacting the conversation…": {
    de: "Das Gespräch wird zusammengefasst…",
    fr: "Résumé de la conversation en cours…",
    es: "Resumiendo la conversación…",
  },
  "Context window {pct} · {used}/{window}": {
    de: "Kontextfenster {pct} · {used}/{window}",
    fr: "Fenêtre de contexte {pct} · {used}/{window}",
    es: "Ventana de contexto {pct} · {used}/{window}",
  },
  "Auto-compact at {tokens}": {
    de: "Automatisches Zusammenfassen bei {tokens}",
    fr: "Résumé automatique à {tokens}",
    es: "Compactación automática en {tokens}",
  },
  "This conversation is getting long: /compact summarizes it before it happens by itself.": {
    de: "Dieses Gespräch wird lang: /compact fasst es zusammen, bevor es von selbst passiert.",
    fr: "Cette conversation devient longue : /compact la résume avant que cela ne se fasse automatiquement.",
    es: "Esta conversación se está alargando: /compact la resume antes de que ocurra automáticamente.",
  },
  "Compacts automatically at about {tokens} tokens.": {
    de: "Fasst automatisch bei etwa {tokens} Tokens zusammen.",
    fr: "Se résume automatiquement autour de {tokens} jetons.",
    es: "Se compacta automáticamente alrededor de {tokens} tokens.",
  },
  "System prompt": { de: "System-Prompt", fr: "Prompt système", es: "Prompt del sistema" },
  "Tool calls": { de: "Tool-Aufrufe", fr: "Appels d'outils", es: "Llamadas a herramientas" },
  "Autocompact buffer": {
    de: "Puffer für automatisches Zusammenfassen",
    fr: "Tampon de compression auto",
    es: "Búfer de compactación automática",
  },
  "Free space": { de: "Freier Platz", fr: "Espace libre", es: "Espacio libre" },
  "Headroom before auto-compact": {
    de: "Spielraum bis zum automatischen Zusammenfassen",
    fr: "Marge avant le résumé automatique",
    es: "Margen antes de la compactación automática",
  },
  "Estimated from the session's usage and timeline.": {
    de: "Geschätzt anhand der Nutzung und des Verlaufs dieser Sitzung.",
    fr: "Estimé à partir de l'utilisation et de l'historique de cette session.",
    es: "Estimado a partir del uso y el historial de esta sesión.",
  },
  "Compact now": { de: "Jetzt zusammenfassen", fr: "Résumer maintenant", es: "Compactar ahora" },
};
