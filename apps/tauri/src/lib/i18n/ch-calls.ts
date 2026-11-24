// German, French, and Spanish for calling from a chat (`I18n+ChatCall.swift` on the Mac).
import type { Table } from "./catalog";

export const table: Table = {
  "Voice call": { de: "Sprachanruf", fr: "Appel vocal", es: "Llamada de voz" },
  "Video call": { de: "Videoanruf", fr: "Appel vidéo", es: "Videollamada" },
  Call: { de: "Anrufen", fr: "Appeler", es: "Llamar" },
  "Call in {app}": { de: "In {app} anrufen", fr: "Appeler dans {app}", es: "Llamar en {app}" },
  "Calling…": { de: "Ruft an …", fr: "Appel en cours…", es: "Llamando…" },
  "In call": { de: "Im Gespräch", fr: "En appel", es: "En llamada" },
  "Call ended": { de: "Anruf beendet", fr: "Appel terminé", es: "Llamada finalizada" },
  "Press call in {app}. Nook follows the call.": {
    de: "Tippe in {app} auf Anrufen. Nook verfolgt den Anruf.",
    fr: "Appuie sur Appeler dans {app}. Nook suit l’appel.",
    es: "Pulsa llamar en {app}. Nook sigue la llamada.",
  },
  Sound: { de: "Ton", fr: "Son", es: "Sonido" },
  Camera: { de: "Kamera", fr: "Caméra", es: "Cámara" },
  "Active call": { de: "Aktiver Anruf", fr: "Appel actif", es: "Llamada activa" },
};
