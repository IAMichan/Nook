// German, French, and Spanish for agent updates and the failed turn's sign-in and update actions (`agentUpdate.*`,
// `ws.recovery.updateAgent`, `accounts.reauth` on the Mac).
import type { Table } from "./catalog";

export const table: Table = {
  "Checking for updates failed": { de: "Die Suche nach Updates ist fehlgeschlagen", fr: "La recherche de mises à jour a échoué", es: "No se pudieron buscar actualizaciones" },
  "Nook cannot tell what installed {agent}. Update it the way you installed it.": {
    de: "Nook kann nicht erkennen, was {agent} installiert hat. Aktualisiere es so, wie du es installiert hast.",
    fr: "Nook ne sait pas ce qui a installé {agent}. Mets-le à jour comme tu l'as installé.",
    es: "Nook no sabe qué instaló {agent}. Actualízalo como lo instalaste.",
  },
  "Installed with {agent}'s own installer: Nook runs its own updater.": {
    de: "Mit dem eigenen Installationsprogramm von {agent} installiert: Nook führt dessen Updater aus.",
    fr: "Installé avec l'installateur de {agent} : Nook lance son propre outil de mise à jour.",
    es: "Instalado con el instalador propio de {agent}: Nook ejecuta su propio actualizador.",
  },
  "Installed with {installer}: Nook runs its update command.": {
    de: "Mit {installer} installiert: Nook führt dessen Update-Befehl aus.",
    fr: "Installé avec {installer} : Nook lance sa commande de mise à jour.",
    es: "Instalado con {installer}: Nook ejecuta su comando de actualización.",
  },
  "Update {agent}?": { de: "{agent} aktualisieren?", fr: "Mettre à jour {agent} ?", es: "¿Actualizar {agent}?" },
  "Update {count} agents?": { de: "{count} Agenten aktualisieren?", fr: "Mettre à jour {count} agents ?", es: "¿Actualizar {count} agentes?" },
  "{count} sessions of these agents are running. They keep the version they started with until they end.": {
    de: "{count} Sitzungen dieser Agenten laufen. Sie behalten ihre Startversion, bis sie enden.",
    fr: "{count} sessions de ces agents sont en cours. Elles gardent leur version de départ jusqu'à leur fin.",
    es: "Hay {count} sesiones de estos agentes en curso. Mantienen la versión con la que empezaron hasta que terminen.",
  },
  "Update all ({count})": { de: "Alle aktualisieren ({count})", fr: "Tout mettre à jour ({count})", es: "Actualizar todo ({count})" },
  "Update available: {version}": { de: "Update verfügbar: {version}", fr: "Mise à jour disponible : {version}", es: "Actualización disponible: {version}" },
  "Up to date": { de: "Aktuell", fr: "À jour", es: "Actualizado" },
  "No agent programs found": { de: "Keine Agentenprogramme gefunden", fr: "Aucun programme d'agent trouvé", es: "No se encontraron programas de agentes" },
  "Once an agent is installed, its program shows here with its version.": {
    de: "Sobald ein Agent installiert ist, erscheint sein Programm hier mit seiner Version.",
    fr: "Dès qu'un agent est installé, son programme apparaît ici avec sa version.",
    es: "En cuanto un agente esté instalado, su programa aparece aquí con su versión.",
  },
  "Log in again": { de: "Erneut anmelden", fr: "Se reconnecter", es: "Volver a iniciar sesión" },
  "Update {agent}": { de: "{agent} aktualisieren", fr: "Mettre à jour {agent}", es: "Actualizar {agent}" },
  "Could not sign in again": { de: "Erneute Anmeldung nicht möglich", fr: "Impossible de se reconnecter", es: "No se pudo volver a iniciar sesión" },
  "Each agent's program, its version and the newest one. Update runs the installer that put it there (npm, pnpm, Bun, Volta, Scoop, mise, or the agent's own updater) after you confirm. Running sessions keep the version they started with.": {
    de: "Das Programm jedes Agenten, seine Version und die neueste. Aktualisieren führt nach deiner Bestätigung das Installationsprogramm aus, das es installiert hat (npm, pnpm, Bun, Volta, Scoop, mise oder den eigenen Updater des Agenten). Laufende Sitzungen behalten die Version, mit der sie begonnen haben.",
    fr: "Le programme de chaque agent, sa version et la plus récente. Mettre à jour lance, après ta confirmation, l'installateur qui l'a mis en place (npm, pnpm, Bun, Volta, Scoop, mise ou le propre outil de mise à jour de l'agent). Les sessions en cours gardent la version avec laquelle elles ont démarré.",
    es: "El programa de cada agente, su versión y la más reciente. Actualizar ejecuta, tras tu confirmación, el instalador que lo puso ahí (npm, pnpm, Bun, Volta, Scoop, mise o el actualizador propio del agente). Las sesiones en curso mantienen la versión con la que empezaron.",
  },
};
