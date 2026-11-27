// "Automatic" under "Runs on", the machines' status, and machines found on this computer.
import type { Table } from "./catalog";

export const table: Table = {
  "Add this one": { de: "Diesen hinzufügen", fr: "Ajouter celle-ci", es: "Añadir esta" },
  "connected before": { de: "früher verbunden", fr: "déjà connectée", es: "conectada antes" },
  "Found on this computer:": { de: "Auf diesem Computer gefunden:", fr: "Trouvées sur cet ordinateur :", es: "Encontradas en este ordenador:" },
  "from your ssh config": { de: "aus deiner ssh-Konfiguration", fr: "de votre configuration ssh", es: "de tu configuración de ssh" },
  "connected": { de: "verbunden", fr: "connectée", es: "conectada" },
  "connecting…": { de: "verbinden…", fr: "connexion…", es: "conectando…" },
  "Less often": { de: "Seltener", fr: "Moins souvent", es: "Con menos frecuencia" },
  "Manual only": { de: "Nur manuell", fr: "Manuel uniquement", es: "Solo manual" },
  "Nook picks this computer or a machine this project is shared with.": {
    de: "Nook wählt diesen Computer oder einen Rechner, auf dem dieses Projekt auch liegt.",
    fr: "Nook choisit cet ordinateur ou une machine avec laquelle ce projet est partagé.",
    es: "Nook elige este ordenador o una máquina con la que se comparte este proyecto.",
  },
  "Nook picks where it runs as it starts: this computer or {machines}.": {
    de: "Nook wählt beim Start, wo er läuft: dieser Computer oder {machines}.",
    fr: "Nook choisit où elle s’exécute au démarrage : cet ordinateur ou {machines}.",
    es: "Nook elige dónde se ejecuta al iniciarse: este ordenador o {machines}.",
  },
  "Normal": { de: "Normal", fr: "Normal", es: "Normal" },
  "Picked automatically": { de: "Automatisch wählen", fr: "Choix automatique", es: "Elección automática" },
  "Prefer": { de: "Bevorzugt", fr: "Préférer", es: "Preferir" },
  "Started on {machine}": { de: "Gestartet auf {machine}", fr: "Lancée sur {machine}", es: "Iniciada en {machine}" },
  "This project is not on another machine yet, so it starts on this computer. Start it once on a machine to share it there.": {
    de: "Dieses Projekt liegt noch auf keinem anderen Rechner, daher startet es auf diesem Computer. Starte es einmal auf einem Rechner, um es dort zu teilen.",
    fr: "Ce projet n’est encore sur aucune autre machine, il démarre donc sur cet ordinateur. Lancez-le une fois sur une machine pour l’y partager.",
    es: "Este proyecto aún no está en ninguna otra máquina, así que se inicia en este ordenador. Inícialo una vez en una máquina para compartirlo allí.",
  },
  "With Automatic under the box, Nook starts a new session on this computer or on a machine the project is shared with: the place that answers, has the agent and has the least to do for its level. A project is shared with a machine once you started a session of it there.": {
    de: "Mit Automatisch unter dem Eingabefeld startet Nook eine neue Sitzung auf diesem Computer oder auf einem Rechner, mit dem das Projekt geteilt ist: dort, wo er erreichbar ist, den Agent hat und für seine Stufe am wenigsten zu tun hat. Ein Projekt ist mit einem Rechner geteilt, sobald du dort einmal eine Sitzung davon gestartet hast.",
    fr: "Avec Automatique sous le champ, Nook lance une nouvelle session sur cet ordinateur ou sur une machine avec laquelle le projet est partagé : l’endroit qui répond, a l’agent et a le moins à faire pour son niveau. Un projet est partagé avec une machine dès que vous y avez lancé une session de ce projet.",
    es: "Con Automático bajo el cuadro, Nook inicia una sesión nueva en este ordenador o en una máquina con la que se comparte el proyecto: el sitio que responde, tiene el agente y tiene menos trabajo para su nivel. Un proyecto se comparte con una máquina en cuanto inicias allí una sesión de él.",
  },
};
