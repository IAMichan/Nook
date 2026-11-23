// German, French, and Spanish for `ag-session-cards` (the suggested-session card and the page card in a session's
// timeline, AG-07 and AG-08); a feature keeps its own file (see catalog.ts).
import type { Table } from "./catalog";

export const table: Table = {
  "Project default": { de: "Projektstandard", fr: "Par défaut du projet", es: "Predeterminado del proyecto" },
  "Do it here": { de: "Hier erledigen", fr: "Le faire ici", es: "Hacerlo aquí" },
  "Starting “{title}”…": { de: "„{title}“ wird gestartet…", fr: "Démarrage de « {title} »…", es: "Iniciando «{title}»…" },
  "Started “{title}” as a new session": { de: "„{title}“ als neue Sitzung gestartet", fr: "« {title} » démarrée comme nouvelle session", es: "«{title}» iniciada como nueva sesión" },
  "“{title}” went to this session": { de: "„{title}“ ging an diese Sitzung", fr: "« {title} » est allée à cette session", es: "«{title}» fue a esta sesión" },
  "Dismissed “{title}”": { de: "„{title}“ verworfen", fr: "« {title} » ignorée", es: "«{title}» descartada" },
  "Page": { de: "Seite", fr: "Page", es: "Página" },
  "This page is no longer there.": { de: "Diese Seite gibt es nicht mehr.", fr: "Cette page n’existe plus.", es: "Esta página ya no está." },
};
