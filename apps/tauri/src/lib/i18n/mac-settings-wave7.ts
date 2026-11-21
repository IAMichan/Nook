// Settings wave 7: Coding agents list+detail & Skills tab (`UI-24`), Worktrees cleanup & source control (`UI-27`),
// and OpenTelemetry export (`SV-05` / `UI-33`), worded as the Mac's I18n (`I18n+Telemetry.swift`,
// `I18n+WorktreeCleanup.swift`, `I18n+SourceControl.swift`, `I18n+AgentMaintenance.swift`, `I18n+Skills.swift`).
import type { Table } from "./catalog";

export const table: Table = {
  // MARK: Agents & Skills (UI-24)
  "Coding agents and skills": {
    de: "Coding-Agenten und Skills",
    fr: "Agents de code et skills",
    es: "Agentes de código y skills",
  },
  Unreadable: {
    de: "Unlesbar",
    fr: "Illisible",
    es: "Ilegible",
  },
  Installed: {
    de: "Installiert",
    fr: "Installé",
    es: "Instalado",
  },
  "Not installed": {
    de: "Nicht installiert",
    fr: "Non installé",
    es: "No instalado",
  },
  Skills: {
    de: "Skills",
    fr: "Skills",
    es: "Skills",
  },
  "Link with Nook": {
    de: "Verbindung mit Nook",
    fr: "Lien avec Nook",
    es: "Vínculo con Nook",
  },
  "Program & updates": {
    de: "Programm & Updates",
    fr: "Programme et mises à jour",
    es: "Programa y actualizaciones",
  },
  "Status and version": {
    de: "Status und Version",
    fr: "État et version",
    es: "Estado y versión",
  },
  "Installed · version {version}": {
    de: "Installiert · Version {version}",
    fr: "Installé · version {version}",
    es: "Instalado · versión {version}",
  },
  "Not found on this computer": {
    de: "Auf diesem Computer nicht gefunden",
    fr: "Introuvable sur cet ordinateur",
    es: "No encontrado en este ordenador",
  },
  "CLI path": {
    de: "CLI-Pfad",
    fr: "Chemin CLI",
    es: "Ruta CLI",
  },
  "Antigravity ACP server": {
    de: "Antigravity-ACP-Server",
    fr: "Serveur ACP Antigravity",
    es: "Servidor ACP de Antigravity",
  },
  "Leave empty to let the agent pick its own default model.": {
    de: "Leer lassen, damit der Agent sein eigenes Standardmodell wählt.",
    fr: "Laissez vide pour laisser l’agent choisir son propre modèle par défaut.",
    es: "Déjalo vacío para que el agente elija su propio modelo predeterminado.",
  },
  "Nook follows sessions of this agent through its link; you start the agent yourself in a terminal or editor.": {
    de: "Nook verfolgt Sitzungen dieses Agenten über seine Verbindung; du startest den Agenten selbst im Terminal oder Editor.",
    fr: "Nook suit les sessions de cet agent via son lien ; vous lancez l’agent vous-même dans un terminal ou un éditeur.",
    es: "Nook sigue las sesiones de este agente mediante su vínculo; tú inicias el agente en un terminal o editor.",
  },
  "Where skills go": {
    de: "Wohin Skills kommen",
    fr: "Où vont les skills",
    es: "Dónde van las skills",
  },
  "A skill is a folder with a SKILL.md that tells an agent how to do something. Nook puts it in the folder each agent reads: for yourself, every project gets it; for one project, it goes in that project and is committed with it.": {
    de: "Ein Skill ist ein Ordner mit einer SKILL.md, die einem Agent sagt, wie etwas geht. Nook legt ihn in den Ordner, den jeder Agent liest: für dich bekommt ihn jedes Projekt; für ein Projekt kommt er in dieses Projekt und wird mit ihm committet.",
    fr: "Un skill est un dossier avec un SKILL.md qui explique à un agent comment faire quelque chose. Nook le place dans le dossier que lit chaque agent : pour vous, chaque projet l’a ; pour un projet, il va dans ce projet et est commité avec lui.",
    es: "Una skill es una carpeta con un SKILL.md que le dice a un agente cómo hacer algo. Nook la pone en la carpeta que lee cada agente: para ti, la tiene cada proyecto; para un proyecto, va en ese proyecto y se incluye en sus commits.",
  },
  Scope: {
    de: "Bereich",
    fr: "Portée",
    es: "Ámbito",
  },
  "In this project's folder; it is committed with the project": {
    de: "Im Ordner dieses Projekts; er wird mit dem Projekt committet",
    fr: "Dans le dossier de ce projet ; il est commité avec le projet",
    es: "En la carpeta de este proyecto; se incluye en sus commits",
  },
  "In your own skills folders, for every project": {
    de: "In deinen eigenen Skill-Ordnern, für jedes Projekt",
    fr: "Dans vos propres dossiers de skills, pour chaque projet",
    es: "En tus propias carpetas de skills, para cada proyecto",
  },
  "Yourself (every project)": {
    de: "Dich (jedes Projekt)",
    fr: "Vous (chaque projet)",
    es: "Ti (cada proyecto)",
  },
  "Agents that read the same folder share one copy": {
    de: "Agents, die denselben Ordner lesen, teilen eine Kopie",
    fr: "Les agents qui lisent le même dossier partagent une copie",
    es: "Los agentes que leen la misma carpeta comparten una copia",
  },
  "Discovered skills": {
    de: "Gefundene Skills",
    fr: "Skills découverts",
    es: "Skills descubiertas",
  },
  "Filter skills…": {
    de: "Skills filtern…",
    fr: "Filtrer les skills…",
    es: "Filtrar skills…",
  },
  "No skills found": {
    de: "Keine Skills gefunden",
    fr: "Aucun skill trouvé",
    es: "No se encontraron skills",
  },
  "Place a folder with a SKILL.md in one of the skill folders below and click Refresh.": {
    de: "Lege einen Ordner mit einer SKILL.md in einen der Skill-Ordner unten und klicke auf Aktualisieren.",
    fr: "Placez un dossier contenant un fichier SKILL.md dans l’un des dossiers de skills ci-dessous puis cliquez sur Actualiser.",
    es: "Coloca una carpeta con un archivo SKILL.md en una de las carpetas de skills de abajo y haz clic en Actualizar.",
  },
  Global: {
    de: "Global",
    fr: "Global",
    es: "Global",
  },
  Inspect: {
    de: "Ansehen",
    fr: "Inspecter",
    es: "Inspeccionar",
  },
  "Comes with {n} scripts an agent can run.": {
    de: "Enthält {n} Skripte, die ein Agent ausführen kann.",
    fr: "Contient {n} scripts qu’un agent peut exécuter.",
    es: "Incluye {n} scripts que un agente puede ejecutar.",
  },
  "No scripts: instructions only.": {
    de: "Keine Skripte: nur Anweisungen.",
    fr: "Aucun script : des instructions seulement.",
    es: "Sin scripts: solo instrucciones.",
  },
  "Skill folders": {
    de: "Skill-Ordner",
    fr: "Dossiers de skills",
    es: "Carpetas de skills",
  },
  "1 skill": {
    de: "1 Skill",
    fr: "1 skill",
    es: "1 skill",
  },
  "{n} skills": {
    de: "{n} Skills",
    fr: "{n} skills",
    es: "{n} skills",
  },
  "Create and open": {
    de: "Erstellen und öffnen",
    fr: "Créer et ouvrir",
    es: "Crear y abrir",
  },

  // MARK: OpenTelemetry export (SV-05 / UI-33)
  Traces: {
    de: "Traces",
    fr: "Traces",
    es: "Trazas",
  },
  Metrics: {
    de: "Metriken",
    fr: "Métriques",
    es: "Métricas",
  },
  Logs: {
    de: "Logs",
    fr: "Journaux",
    es: "Registros",
  },
  "Enter an http or https address.": {
    de: "Gib eine http- oder https-Adresse ein.",
    fr: "Saisissez une adresse http ou https.",
    es: "Escribe una dirección http o https.",
  },
  "The headers could not be saved in the Keychain.": {
    de: "Die Header konnten nicht im Schlüsselbund gespeichert werden.",
    fr: "Les en-têtes n’ont pas pu être enregistrés dans le trousseau.",
    es: "No se pudieron guardar las cabeceras en el llavero.",
  },
  "The receiver took an empty export (HTTP {status}).": {
    de: "Der Empfänger hat einen leeren Export angenommen (HTTP {status}).",
    fr: "Le récepteur a accepté un export vide (HTTP {status}).",
    es: "El receptor aceptó una exportación vacía (HTTP {status}).",
  },
  "The receiver answered HTTP {status}.": {
    de: "Der Empfänger antwortete HTTP {status}.",
    fr: "Le récepteur a répondu HTTP {status}.",
    es: "El receptor respondió HTTP {status}.",
  },
  "No answer: {message}": {
    de: "Keine Antwort: {message}",
    fr: "Pas de réponse : {message}",
    es: "Sin respuesta: {message}",
  },
  "OpenTelemetry export": {
    de: "OpenTelemetry-Export",
    fr: "Export OpenTelemetry",
    es: "Exportación OpenTelemetry",
  },
  "Sends traces, metrics and logs to an OpenTelemetry receiver of your own (a collector, Grafana, Honeycomb…). Enter each signal's OTLP HTTP endpoint, for example http://localhost:4318/v1/traces; an empty field sends nothing. Nook sends its agent turns, scheduled task runs and launch time, without prompts, answers or file contents, and passes the receiver on to every coding agent it starts that can export on its own. Standard OTEL_EXPORTER_OTLP_* variables in Nook's environment override these fields.": {
    de: "Sendet Traces, Metriken und Logs an einen eigenen OpenTelemetry-Empfänger (einen Collector, Grafana, Honeycomb…). Gib für jedes Signal den OTLP-HTTP-Endpunkt ein, zum Beispiel http://localhost:4318/v1/traces; ein leeres Feld sendet nichts. Nook sendet seine Agent-Durchläufe, geplanten Aufgaben und Startzeit, ohne Prompts, Antworten oder Dateiinhalte, und gibt den Empfänger an jeden Coding-Agenten weiter, den es startet und der selbst exportieren kann. Standardvariablen OTEL_EXPORTER_OTLP_* in Nooks Umgebung haben Vorrang vor diesen Feldern.",
    fr: "Envoie traces, métriques et journaux à votre propre récepteur OpenTelemetry (un collecteur, Grafana, Honeycomb…). Saisissez le point de terminaison OTLP HTTP de chaque signal, par exemple http://localhost:4318/v1/traces ; un champ vide n’envoie rien. Nook envoie ses tours d’agent, ses tâches planifiées et son temps de lancement, sans prompts, réponses ni contenu de fichiers, et transmet le récepteur à chaque agent de code qu’il lance et qui sait exporter lui-même. Les variables standard OTEL_EXPORTER_OTLP_* de l’environnement de Nook l’emportent sur ces champs.",
    es: "Envía trazas, métricas y registros a tu propio receptor OpenTelemetry (un colector, Grafana, Honeycomb…). Escribe el endpoint OTLP HTTP de cada señal, por ejemplo http://localhost:4318/v1/traces; un campo vacío no envía nada. Nook envía sus turnos de agente, tareas programadas y tiempo de arranque, sin prompts, respuestas ni contenido de archivos, y pasa el receptor a cada agente de código que inicia y que sabe exportar por sí mismo. Las variables estándar OTEL_EXPORTER_OTLP_* del entorno de Nook tienen prioridad sobre estos campos.",
  },
  "Enable OpenTelemetry export": {
    de: "OpenTelemetry-Export aktivieren",
    fr: "Activer l’export OpenTelemetry",
    es: "Activar exportación OpenTelemetry",
  },
  "Set by environment ({variable})": {
    de: "Von der Umgebung gesetzt ({variable})",
    fr: "Défini par l’environnement ({variable})",
    es: "Definido por el entorno ({variable})",
  },
  "Off by default. When off, Nook sends nothing unless OTEL_EXPORTER_OTLP_* is set in the environment.": {
    de: "Standardmäßig aus. Wenn aus, sendet Nook nichts, außer OTEL_EXPORTER_OTLP_* ist in der Umgebung gesetzt.",
    fr: "Désactivé par défaut. Lorsqu’il est désactivé, Nook n’envoie rien sauf si OTEL_EXPORTER_OTLP_* est défini dans l’environnement.",
    es: "Desactivado por defecto. Si está desactivado, Nook no envía nada salvo que OTEL_EXPORTER_OTLP_* esté definido en el entorno.",
  },
  "Protocol for agents": {
    de: "Protokoll für Agenten",
    fr: "Protocole pour les agents",
    es: "Protocolo para agentes",
  },
  "How agents encode what they send. Pick http/json for receivers that do not accept protobuf.": {
    de: "Wie Agenten kodieren, was sie senden. Wähle http/json für Empfänger, die kein Protobuf annehmen.",
    fr: "Comment les agents encodent ce qu’ils envoient. Choisissez http/json pour les récepteurs qui n’acceptent pas protobuf.",
    es: "Cómo codifican los agentes lo que envían. Elige http/json para receptores que no aceptan protobuf.",
  },
  Headers: {
    de: "Header",
    fr: "En-têtes",
    es: "Cabeceras",
  },
  "{n} headers": {
    de: "{n} Header",
    fr: "{n} en-têtes",
    es: "{n} cabeceras",
  },
  "Saved in the Keychain; sent with every export.": {
    de: "Im Schlüsselbund gespeichert; wird mit jedem Export gesendet.",
    fr: "Enregistrés dans le trousseau ; envoyés avec chaque export.",
    es: "Guardadas en el llavero; se envían con cada exportación.",
  },
  "For receivers that need a key: key=value, separated by commas. Saved in the Keychain on Return.": {
    de: "Für Empfänger, die einen Schlüssel brauchen: schlüssel=wert, durch Kommas getrennt. Mit Return im Schlüsselbund gespeichert.",
    fr: "Pour les récepteurs qui demandent une clé : clé=valeur, séparés par des virgules. Enregistrés dans le trousseau avec Retour.",
    es: "Para receptores que piden una clave: clave=valor, separados por comas. Se guardan en el llavero con Retorno.",
  },
  "Nook's own export uses OTLP/HTTP JSON. Agents use the receiver from their next start; sessions on another machine are left out.": {
    de: "Nooks eigener Export nutzt OTLP/HTTP JSON. Agenten nutzen den Empfänger ab ihrem nächsten Start; Sitzungen auf einem anderen Rechner nicht.",
    fr: "L’export de Nook lui-même utilise OTLP/HTTP JSON. Les agents utilisent le récepteur dès leur prochain lancement ; pas les sessions sur une autre machine.",
    es: "La exportación propia de Nook usa OTLP/HTTP JSON. Los agentes usan el receptor desde su próximo inicio; las sesiones en otra máquina no.",
  },

  // MARK: Worktrees Cleanup & Source Control (UI-27)
  Removed: {
    de: "Entfernt",
    fr: "Supprimé",
    es: "Eliminado",
  },
  Kept: {
    de: "Behalten",
    fr: "Conservé",
    es: "Conservado",
  },
  "pull request merged": {
    de: "Pull Request gemergt",
    fr: "pull request fusionnée",
    es: "pull request fusionada",
  },
  "session settled": {
    de: "Sitzung erledigt",
    fr: "session terminée",
    es: "sesión terminada",
  },
  "session quiet": {
    de: "Sitzung ruhig",
    fr: "session inactive",
    es: "sesión inactiva",
  },
  "nothing beyond the base branch": {
    de: "nichts über den Basis-Branch hinaus",
    fr: "rien au-delà de la branche de base",
    es: "nada más allá de la rama base",
  },
  "session deleted": {
    de: "Sitzung gelöscht",
    fr: "session supprimée",
    es: "sesión eliminada",
  },
  "in use": {
    de: "in Gebrauch",
    fr: "en cours d'utilisation",
    es: "en uso",
  },
  "a terminal is open in it": {
    de: "ein Terminal ist darin offen",
    fr: "un terminal y est ouvert",
    es: "hay un terminal abierto en él",
  },
  "another session uses it": {
    de: "eine andere Sitzung nutzt ihn",
    fr: "une autre session l'utilise",
    es: "otra sesión lo usa",
  },
  "a symbolic link": {
    de: "ein symbolischer Link",
    fr: "un lien symbolique",
    es: "un enlace simbólico",
  },
  "another branch is checked out": {
    de: "ein anderer Branch ist ausgecheckt",
    fr: "une autre branche est extraite",
    es: "hay otra rama activa",
  },
  "local changes": {
    de: "lokale Änderungen",
    fr: "modifications locales",
    es: "cambios locales",
  },
  "commits that are not pushed": {
    de: "nicht gepushte Commits",
    fr: "commits non poussés",
    es: "commits sin subir",
  },
  "Fast worktrees": {
    de: "Schnelle Worktrees",
    fr: "Worktrees rapides",
    es: "Worktrees rápidos",
  },
  "New worktrees are copy-on-write clones of a cached checkout when the filesystem supports it, so a large repository opens quickly; anything unusual uses plain git worktree add.": {
    de: "Neue Worktrees sind Copy-on-Write-Klone eines zwischengespeicherten Checkouts, wenn das Dateisystem es unterstützt, sodass große Repositorys schnell öffnen; alles Ungewöhnliche nutzt einfaches git worktree add.",
    fr: "Les nouveaux worktrees sont des clones copy-on-write d’un checkout mis en cache lorsque le système de fichiers le permet, afin qu’un grand dépôt s’ouvre rapidement ; tout cas particulier utilise simplement git worktree add.",
    es: "Los nuevos worktrees son clones copy-on-write de un checkout en caché cuando el sistema de archivos lo permite, para abrir rápido repositorios grandes; cualquier caso especial usa git worktree add normal.",
  },
  Submodules: {
    de: "Submodule",
    fr: "Sous-modules",
    es: "Submódulos",
  },
  "How a new worktree checks out the repository's submodules. Skip when a setup script does it.": {
    de: "Wie ein neuer Worktree die Submodule des Repositorys auscheckt. Überspringen, wenn ein Setup-Skript das erledigt.",
    fr: "Comment un nouveau worktree extrait les sous-modules du dépôt. Ignorer si un script d'installation s'en charge.",
    es: "Cómo un worktree nuevo obtiene los submódulos del repositorio. Omitir si lo hace un script de configuración.",
  },
  "All, recursively": {
    de: "Alle, rekursiv",
    fr: "Tous, récursivement",
    es: "Todos, recursivamente",
  },
  "Top level only": {
    de: "Nur oberste Ebene",
    fr: "Premier niveau seulement",
    es: "Solo el nivel superior",
  },
  Skip: {
    de: "Überspringen",
    fr: "Ignorer",
    es: "Omitir",
  },
  "Keep the default branch up to date": {
    de: "Standardbranch aktuell halten",
    fr: "Garder la branche par défaut à jour",
    es: "Mantener actualizada la rama predeterminada",
  },
  "About every 15 minutes Nook fetches the default branch and fast-forwards the main checkout, only when it is on that branch, has no changes, and no session works in it. Never a merge.": {
    de: "Etwa alle 15 Minuten holt Nook die Standardbranch und spult den Haupt-Checkout vor, nur wenn er auf dieser Branch ist, keine Änderungen hat und keine Sitzung darin arbeitet. Nie ein Merge.",
    fr: "Environ toutes les 15 minutes, Nook récupère la branche par défaut et fait avancer la copie principale, uniquement si elle est sur cette branche, sans modifications et sans session en cours dedans. Jamais de fusion.",
    es: "Cada 15 minutos aproximadamente, Nook descarga la rama predeterminada y avanza la copia principal, solo si está en esa rama, no tiene cambios y ninguna sesión trabaja en ella. Nunca una fusión.",
  },
  "Clone into host/owner/repo": {
    de: "In Host/Besitzer/Repo klonen",
    fr: "Cloner dans hôte/propriétaire/dépôt",
    es: "Clonar en host/propietario/repo",
  },
  "A clone goes to github.com/owner/repo under ~/Developer (or under the folder your current project's layout starts at).": {
    de: "Ein Klon landet in github.com/besitzer/repo unter ~/Developer (oder unter dem Ordner, in dem die Struktur deines aktuellen Projekts beginnt).",
    fr: "Un clone va dans github.com/propriétaire/dépôt sous ~/Developer (ou sous le dossier où commence l'organisation de votre projet actuel).",
    es: "Un clon va a github.com/propietario/repo dentro de ~/Developer (o de la carpeta donde empieza la estructura de tu proyecto actual).",
  },
  "Worktree cleanup": {
    de: "Worktrees aufräumen",
    fr: "Nettoyage des worktrees",
    es: "Limpieza de worktrees",
  },
  "Remove the worktree once its pull request is merged": {
    de: "Worktree entfernen, sobald der Pull Request gemergt ist",
    fr: "Supprimer le worktree une fois sa pull request fusionnée",
    es: "Eliminar el worktree cuando su pull request se haya fusionado",
  },
  "Remove the worktree after a settled session": {
    de: "Worktree nach einer erledigten Sitzung entfernen",
    fr: "Supprimer le worktree après une session terminée",
    es: "Eliminar el worktree tras una sesión terminada",
  },
  "Remove the worktree after a quiet session": {
    de: "Worktree nach einer ruhigen Sitzung entfernen",
    fr: "Supprimer le worktree après une session inactive",
    es: "Eliminar el worktree tras una sesión inactiva",
  },
  "Remove a worktree with no commits beyond its base branch": {
    de: "Worktree ohne Commits über den Basis-Branch hinaus entfernen",
    fr: "Supprimer un worktree sans commit au-delà de sa branche de base",
    es: "Eliminar un worktree sin commits más allá de su rama base",
  },
  "Remove the worktree when its last session is deleted": {
    de: "Worktree entfernen, wenn seine letzte Sitzung gelöscht wird",
    fr: "Supprimer le worktree quand sa dernière session est supprimée",
    es: "Eliminar el worktree cuando se elimine su última sesión",
  },
  "Keep a worktree with": {
    de: "Worktree behalten bei",
    fr: "Conserver un worktree avec",
    es: "Conservar un worktree con",
  },
  "Uncommitted changes: edited and new files keep the worktree; ignored files such as builds and .env go with it. Any local files: ignored files keep it too (except node_modules). Edited tracked files: only edits to tracked files keep it.": {
    de: "Nicht committete Änderungen: geänderte und neue Dateien behalten den Worktree; ignorierte Dateien wie Builds und .env gehen mit. Alle lokalen Dateien: auch ignorierte Dateien behalten ihn (außer node_modules). Geänderte verfolgte Dateien: nur Änderungen an verfolgten Dateien behalten ihn.",
    fr: "Modifications non validées : les fichiers modifiés et nouveaux conservent le worktree ; les fichiers ignorés comme les builds et .env partent avec lui. Tout fichier local : les fichiers ignorés le conservent aussi (sauf node_modules). Fichiers suivis modifiés : seules les modifications de fichiers suivis le conservent.",
    es: "Cambios sin confirmar: los archivos editados y nuevos conservan el worktree; los archivos ignorados como compilaciones y .env se van con él. Cualquier archivo local: los archivos ignorados también lo conservan (excepto node_modules). Archivos rastreados editados: solo las ediciones de archivos rastreados lo conservan.",
  },
  "Uncommitted changes": {
    de: "Nicht committeten Änderungen",
    fr: "Modifications non validées",
    es: "Cambios sin confirmar",
  },
  "Any local files": {
    de: "Allen lokalen Dateien",
    fr: "Tout fichier local",
    es: "Cualquier archivo local",
  },
  "Edited tracked files": {
    de: "Geänderten verfolgten Dateien",
    fr: "Fichiers suivis modifiés",
    es: "Archivos rastreados editados",
  },
  "Latest cleanup": {
    de: "Letztes Aufräumen",
    fr: "Dernier nettoyage",
    es: "Última limpieza",
  },
  "{stale} of {total} worktrees ready to clean up.": {
    de: "{stale} von {total} Worktrees bereit zum Aufräumen.",
    fr: "{stale} sur {total} worktrees prêts à être nettoyés.",
    es: "{stale} de {total} worktrees listos para limpiar.",
  },
  "{total} active worktrees, no stale worktrees.": {
    de: "{total} aktive Worktrees, keine veralteten Worktrees.",
    fr: "{total} worktrees actifs, aucun worktree obsolète.",
    es: "{total} worktrees activos, ningún worktree obsoleto.",
  },
  "No extra worktrees found.": {
    de: "Keine zusätzlichen Worktrees gefunden.",
    fr: "Aucun worktree supplémentaire trouvé.",
    es: "No se encontraron worktrees adicionales.",
  },
  "No cleanup has run yet.": {
    de: "Es wurde noch nicht aufgeräumt.",
    fr: "Aucun nettoyage n'a encore eu lieu.",
    es: "Todavía no se ha limpiado nada.",
  },
  "No rule applied to any worktree.": {
    de: "Keine Regel traf auf einen Worktree zu.",
    fr: "Aucune règle ne s'appliquait à un worktree.",
    es: "Ninguna regla se aplicó a un worktree.",
  },
  "{removed} removed · {kept} kept · {failed} failed": {
    de: "{removed} entfernt · {kept} behalten · {failed} fehlgeschlagen",
    fr: "{removed} supprimés · {kept} conservés · {failed} échoués",
    es: "{removed} eliminados · {kept} conservados · {failed} fallidos",
  },
  "{size} freed": {
    de: "{size} freigegeben",
    fr: "{size} libérés",
    es: "{size} liberados",
  },
  "Cleaning up…": {
    de: "Wird aufgeräumt…",
    fr: "Nettoyage…",
    es: "Limpiando…",
  },
  "Clean up now": {
    de: "Jetzt aufräumen",
    fr: "Nettoyer maintenant",
    es: "Limpiar ahora",
  },
  "Folders no session uses": {
    de: "Ordner, die keine Sitzung nutzt",
    fr: "Dossiers qu'aucune session n'utilise",
    es: "Carpetas que ninguna sesión usa",
  },
  "In Nook's worktree folder, untouched for an hour and used by no session. Cleanup never removes them; remove them under Worktrees if you no longer need them.": {
    de: "Im Worktree-Ordner von Nook, seit einer Stunde unberührt und von keiner Sitzung genutzt. Das Aufräumen entfernt sie nie; entferne sie unter Worktrees, wenn du sie nicht mehr brauchst.",
    fr: "Dans le dossier de worktrees de Nook, intouchés depuis une heure et utilisés par aucune session. Le nettoyage ne les supprime jamais ; supprimez-les sous Worktrees si vous n'en avez plus besoin.",
    es: "En la carpeta de worktrees de Nook, sin tocar desde hace una hora y sin uso por ninguna sesión. La limpieza nunca las elimina; elimínalas en Worktrees si ya no las necesitas.",
  },
};
