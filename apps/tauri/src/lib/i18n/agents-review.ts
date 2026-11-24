// German, French, and Spanish for reviewing a session's diff: stage or discard a hunk, comment on a line
// (`agents.diff.hunk.*`, `ws.review.*` on the Mac), and editing a plan's steps before it runs (`ws.plan.*`).
import type { Table } from "./catalog";

export const table: Table = {
  "Stage this hunk": { de: "Diesen Block stagen", fr: "Indexer ce bloc", es: "Preparar este bloque" },
  "Discard this hunk": { de: "Diesen Block verwerfen", fr: "Annuler ce bloc", es: "Descartar este bloque" },
  "Comment on this line": { de: "Kommentar zu dieser Zeile", fr: "Commenter cette ligne", es: "Comentar esta línea" },
  "Discard this change?": { de: "Diese Änderung verwerfen?", fr: "Annuler cette modification ?", es: "¿Descartar este cambio?" },
  "The lines of this hunk are taken out of {file} again. This cannot be undone.": {
    de: "Die Zeilen dieses Blocks werden wieder aus {file} entfernt. Das lässt sich nicht rückgängig machen.",
    fr: "Les lignes de ce bloc sont retirées de {file}. Cette action est irréversible.",
    es: "Las líneas de este bloque se quitan de {file}. No se puede deshacer.",
  },
  "Discard": { de: "Verwerfen", fr: "Abandonner", es: "Descartar" },
  "Hunk staged": { de: "Block gestaged", fr: "Bloc indexé", es: "Bloque preparado" },
  "Hunk discarded": { de: "Block verworfen", fr: "Bloc annulé", es: "Bloque descartado" },
  "This hunk could not be applied": { de: "Dieser Block ließ sich nicht anwenden", fr: "Ce bloc n’a pas pu être appliqué", es: "No se pudo aplicar este bloque" },
  "Send to agent": { de: "An Agenten senden", fr: "Envoyer à l'agent", es: "Enviar al agente" },
  "{count} comments ready for the agent": { de: "{count} Kommentare bereit für den Agenten", fr: "{count} commentaires prêts pour l'agent", es: "{count} comentarios listos para el agente" },
  "In a new session": { de: "In einer neuen Sitzung", fr: "Dans une nouvelle session", es: "En una sesión nueva" },
  "Done editing": { de: "Fertig", fr: "Terminé", es: "Listo" },
  "Edit steps": { de: "Schritte bearbeiten", fr: "Modifier les étapes", es: "Editar pasos" },
  "{kept} of {total} steps will run": { de: "{kept} von {total} Schritten werden ausgeführt", fr: "{kept} étapes sur {total} seront exécutées", es: "Se ejecutarán {kept} de {total} pasos" },
};
