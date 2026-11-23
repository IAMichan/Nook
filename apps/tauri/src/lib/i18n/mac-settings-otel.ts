// OpenTelemetry export (`SV-05` / `UI-33`): the strings that say where the headers are kept, worded as the Mac's
// `I18n+Telemetry.swift` with "your system's keychain" (Windows Credential Manager, GNOME Keyring/KWallet) for the Mac's
// Keychain. The rest of the section is in `mac-settings-wave7.ts`.
import type { Table } from "./catalog";

export const table: Table = {
  "For receivers that need a key: key=value, separated by commas. Saved in your system's keychain on Enter.": {
    de: "Für Empfänger, die einen Schlüssel brauchen: schlüssel=wert, durch Kommas getrennt. Mit Enter im Schlüsselbund deines Systems gespeichert.",
    fr: "Pour les récepteurs qui demandent une clé : clé=valeur, séparés par des virgules. Enregistrés dans le trousseau de ton système avec Entrée.",
    es: "Para receptores que piden una clave: clave=valor, separados por comas. Se guardan en el llavero de tu sistema con Intro.",
  },
  "Saved in your system's keychain; sent with every export.": {
    de: "Im Schlüsselbund deines Systems gespeichert; wird mit jedem Export gesendet.",
    fr: "Enregistrés dans le trousseau de ton système ; envoyés avec chaque export.",
    es: "Guardadas en el llavero de tu sistema; se envían con cada exportación.",
  },
  "The headers could not be saved in your system's keychain.": {
    de: "Die Header konnten nicht im Schlüsselbund deines Systems gespeichert werden.",
    fr: "Les en-têtes n’ont pas pu être enregistrés dans le trousseau de ton système.",
    es: "No se pudieron guardar las cabeceras en el llavero de tu sistema.",
  },
};
