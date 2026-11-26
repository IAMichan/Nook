// The Settings search over every setting (the Mac's `SettingsSearch` and `SettingsHighlight`): each setting by the name
// it has on screen, with the subject that shows it. Opening a hit opens that subject, opens the fold the setting sits
// in, scrolls the row into the middle and lights it for a moment. The names are the pages' own `tr` pairs, so the
// search finds a setting in every language exactly as it reads on the page; `settings-search.test.ts` checks that every
// name still appears on a Settings page.
import { tr } from "./i18n.svelte";
import { matchesSearch } from "./shell-routes";
import type { SettingsSectionId } from "./settings-pages";

/** Dutch name, English name, and the subject that shows it. */
export const SETTINGS_INDEX: readonly (readonly [string, string, SettingsSectionId])[] = [
  ["Taal van de app", "App language", "general"],
  ["Taal van antwoorden", "Answer language", "general"],
  ["Sessielijst", "Session list", "general"],
  ["Groepeer sessies per project", "Group sessions by project", "general"],
  ["Toon sessies die aan het werk zijn op een eigen plank", "Show working sessions on their own shelf", "general"],
  ["Bevestigingen", "Confirmations", "general"],
  ["Vragen voor stoppen terwijl sessies werken", "Ask before quitting while sessions are working", "general"],
  ["Nook in de balk", "Nook in the bar", "notch"],
  ["Plek", "Position", "notch"],
  ["Toon Nook op elk scherm", "Show Nook on every screen", "notch"],
  ["Scherm", "Screen", "notch"],
  ["Verberg Nook als er niets is", "Hide Nook when idle", "notch"],
  ["Open het paneel als ik naar de balk wijs", "Open panel when hovering over the bar", "notch"],
  ["Open het hoofdvenster als Nook start", "Open the main window when Nook starts", "notch"],
  ["Starten als ik inlog op de computer", "Open at login", "notch"],
  ["Snelkoppeling in het Startmenu", "Start menu shortcut", "notch"],
  ["Meetings en scherm delen", "Meetings and screen sharing", "notch"],
  ["Als je je scherm deelt", "When you share your screen", "notch"],
  ["Tijdens een meeting", "During a meeting", "notch"],
  ["Afspraken in je agenda tellen mee", "Count events in your calendar", "notch"],
  ["Nook altijd buiten schermdelen houden", "Always keep Nook out of screen sharing", "notch"],
  ["Nook tonen in je schermafbeeldingen", "Show Nook in your screenshots", "notch"],
  ["Stijl", "Style", "appearance"],
  ["Kleur", "Color", "appearance"],
  ["Gezicht en afwerking", "Face and finish", "appearance"],
  ["Ogen", "Eyes", "appearance"],
  ["Mond", "Mouth", "appearance"],
  ["Glans", "Gloss", "appearance"],
  ["Gloed", "Glow", "appearance"],
  ["Blosjes", "Blush", "appearance"],
  ["Nook als maatje", "Nook as a buddy", "appearance"],
  ["Kleine momenten", "Little moments", "appearance"],
  ["Thema", "Theme", "appearance"],
  ["Weergave", "Appearance", "appearance"],
  ["Tekst en indeling", "Text and layout", "appearance"],
  ["Dichtheid", "Density", "appearance"],
  ["Diffkleuren", "Diff colors", "appearance"],
  ["Wiskunde weergeven", "Render math", "appearance"],
  ["Markdown opmaken tijdens het typen", "Style Markdown as you type", "appearance"],
  ["Eigen kleuren", "Custom colors", "appearance"],
  ["Je look delen", "Share your look", "appearance"],
  ["Hoe meldingen verschijnen", "How notifications show", "notifications"],
  ["Stille uren", "Quiet hours", "notifications"],
  ["Agents", "Agents", "notificationApps"],
  ["Geluiden", "Sounds", "sound"],
  ["Geluid als een agent op je wacht of klaar is", "Sound when an agent is waiting or finished", "sound"],
  ["Eigen geluiden", "Custom sounds", "sound"],
  ["Praten", "Speaking", "sound"],
  ["Lees antwoorden voor als ik iets zeg", "Read answers aloud when I speak", "sound"],
  ["Luister naar “Hé Nook”", "Listen for “Hey Nook”", "sound"],
  ["Overal op je computer", "Anywhere on your computer", "shortcuts"],
  ["Vraag over een deel van het scherm", "Ask about a part of the screen", "shortcuts"],
  ["Gesprek opnemen", "Record a call", "shortcuts"],
  ["Paneeltoetsen", "Panel keys", "shortcuts"],
  ["Gamer Mode aan", "Gamer Mode enabled", "games"],
  ["Kijk elke", "Look every", "games"],
  ["Laat nieuwe coaching zien als melding", "Show new coaching as a notice", "games"],
  ["Waar Nook denkt", "Where Nook thinks", "brain"],
  ["Verbinding", "Connection", "brain"],
  ["Alle modellen en runtimes", "All models and runtimes", "brain"],
  ["Draait met", "Runs with", "brain"],
  ["Lokaal brein zelf starten", "Start the local brain myself", "brain"],
  ["Dienst", "Service", "brain"],
  ["Sleutel", "Key", "brain"],
  ["Of log in bij OpenRouter", "Or sign in to OpenRouter", "brain"],
  ["Schermwerk", "Screen work", "brain"],
  ["Wie leest je scherm", "Who reads your screen", "brain"],
  ["Kwaliteit van het lokale brein", "Local brain quality", "brain"],
  ["Bewijs eerst", "Evidence first", "brain"],
  ["Antwoorden controleren", "Check answers", "brain"],
  ["Wat Nook ziet", "What Nook sees", "assistant"],
  ["Houd al mijn schermen bij", "Track all my screens", "assistant"],
  ["Gebruik mijn schermen bij elke vraag", "Use my screens with every question", "assistant"],
  ["Klembord", "Clipboard", "assistant"],
  ["Bestanden", "Files", "assistant"],
  ["Gesprekken", "Calls", "assistant"],
  ["Meedenken", "Proactive suggestions", "assistant"],
  ["Vraag over geselecteerde tekst", "Ask about selected text", "assistant"],
  ["Zoek op het web als dat nodig is", "Search the web when needed", "assistant"],
  ["Denk mee terwijl ik werk", "Suggest ideas while I work", "assistant"],
  ["Niet meedenken in", "Don't think along in", "assistant"],
  ["Wat Nook zelf mag", "What Nook may do", "assistant"],
  ["Nook onthoudt en leert", "Nook remembers and learns", "memory"],
  ["Gebruik mijn geheugen", "Use my memory", "memory"],
  ["Leer vanzelf", "Learn by itself", "memory"],
  ["Geleerde bronnen", "Learned sources", "memory"],
  ["Antwoordstijl", "Answer style", "instructions"],
  ["Standaardstijl", "Default style", "instructions"],
  ["Jouw instructies", "Your instructions", "instructions"],
  ["Bewaarde prompts", "Saved prompts", "instructions"],
  ["Ruimtes", "Spaces", "instructions"],
  ["Contextinspecteur", "Context inspector", "instructions"],
  ["Typ minder, in elke app", "Type less, in any app", "autocomplete"],
  ["Zinnen aanvullen terwijl je typt", "Complete sentences as you type", "autocomplete"],
  ["Woorden van vandaag in de tooltip van het systeemvak", "Words today in the tray tooltip", "autocomplete"],
  ["In de composers van Nook", "In Nook's composers", "autocomplete"],
  ["Acties voorstellen uit gesprekken", "Suggest actions from conversations", "autocomplete"],
  ["Model voor voorstellen", "Model for suggestions", "autocomplete"],
  ["Voorstellen", "Suggestions", "autocomplete"],
  ["Hoe gretig", "How eager", "autocomplete"],
  ["Midden in een regel", "In the middle of a line", "autocomplete"],
  ["Spatie meenemen na een woord", "Include the space after a word", "autocomplete"],
  ["Leestekens meenemen met een woord", "Include punctuation with a word", "autocomplete"],
  ["Toetsen", "Keys", "autocomplete"],
  ["Volgende woord", "Next word", "autocomplete"],
  ["Alles", "Everything", "autocomplete"],
  ["Apps", "Apps", "autocompleteApps"],
  ["Tab aan de app laten", "Leave Tab to the app", "autocompleteApps"],
  ["Wat het model weet", "What the model knows", "autocompleteStyle"],
  ["Jouw stijl", "Your style", "autocompleteStyle"],
  ["Over jou en hoe je schrijft", "About you and how you write", "autocompleteStyle"],
  ["Emoji", "Emoji", "autocompleteStyle"],
  ["Emoji met een dubbele punt", "Emoji with a colon", "autocompleteStyle"],
  ["Huidskleur", "Skin tone", "autocompleteStyle"],
  ["Spelling", "Spelling", "autocompleteStyle"],
  ["Brits of Amerikaans, zoals jij schrijft", "British or American, the way you write", "autocompleteStyle"],
  ["Typtijd bespaard", "Typing time saved", "autocompleteStats"],
  ["Waar je het meest aanvult", "Where you complete the most", "autocompleteStats"],
  ["Overal dicteren", "Dictate anywhere", "dictation"],
  ["Dicteren aanzetten", "Turn on dictation", "dictation"],
  ["Netjes maken door Nook", "Tidy up by Nook", "dictation"],
  ["Promptmodus", "Prompt mode", "dictation"],
  ["Plakken in", "Paste in", "dictation"],
  ["Geschiedenis bewaren", "Keep history", "dictation"],
  ["Woordenboek", "Dictionary", "dictation"],
  ["Spraakherkenning", "Speech recognition", "dictation"],
  ["Model van whisper.cpp", "whisper.cpp model", "dictation"],
  ["Je agents", "Your agents", "agents"],
  ["Accounts", "Accounts", "agents"],
  ["Waar skills komen", "Where skills go", "skills"],
  ["Skill-mappen", "Skill folders", "skills"],
  ["Weekoverzicht", "Weekly recap", "usage"],
  ["Kosten tonen die agents zelf melden", "Show costs reported by agents", "usage"],
  ["Abonnementen", "Subscriptions", "usage"],
  ["Sessies gestart in Nook", "Sessions started in Nook", "usage"],
  ["Nieuwe sessie", "New session", "sessions"],
  ["Standaard-agent", "Default agent", "sessions"],
  ["Standaardmodus", "Default mode", "sessions"],
  ["Standaardrechten", "Default permissions", "sessions"],
  ["Standaard-isolatie", "Default isolation", "sessions"],
  ["Model per agent", "Model per agent", "sessions"],
  ["Gedrag", "Behavior", "sessions"],
  ["Sessietitels automatisch laten schrijven (klein model)", "Write session titles automatically (small model)", "sessions"],
  ["Eigen regels voor titels", "Your own rules for titles", "sessions"],
  ["Instructies voor elke agent", "Instructions for every agent", "sessions"],
  ["Een bericht tijdens een beurt stuurt de agent bij (Ctrl+Enter zet het in de wachtrij)", "A message during a turn steers the agent (Ctrl+Enter queues it)", "sessions"],
  ["Als een sessie stopt of Nook herstart", "When a session stops or Nook restarts", "sessions"],
  ["Na een gebruikslimiet vanzelf verdergaan zodra die vrij is", "Resume automatically once a usage limit resets", "sessions"],
  ["Opruimen", "Tidying up", "sessions"],
  ["Automatisch archiveren na", "Archive automatically after", "sessions"],
  ["Werk van de agent in de tijdlijn", "Agent's work in the timeline", "sessions"],
  ["Meldingen voor schermlezers", "Screen reader announcements", "sessions"],
  ["Oude sessies automatisch afhandelen", "Settle old sessions automatically", "sessions"],
  ["Snooze-opties", "Snooze options", "sessions"],
  ["Nieuwe worktrees", "New worktrees", "worktrees"],
  ["Map voor worktrees", "Worktree folder", "worktrees"],
  ["Prefix voor branches", "Branch prefix", "worktrees"],
  ["Worktrees opruimen", "Worktree cleanup", "worktrees"],
  ["Openen in", "Open in", "openIn"],
  ["Editor", "Editor", "openIn"],
  ["Terminal", "Terminal", "openIn"],
  ["De browser van Nook", "Nook's browser", "openIn"],
  ["Zoekmachine in de browser", "Browser search engine", "openIn"],
  ["Links in een gesprek openen in", "Open links in a conversation in", "openIn"],
  ["Bezochte pagina's onthouden", "Remember visited pages", "openIn"],
  ["Sessies", "Sessions", "archive"],
  ["Nook-gesprekken", "Nook conversations", "archive"],
  ["Geplande taken", "Scheduled tasks", "automation"],
  ["Geplande taken toestaan", "Allow scheduled tasks", "automation"],
  ["Poort voor webhooks (0 = uit)", "Port for webhooks (0 = off)", "automation"],
  ["Werkruimte voor agents", "Workspace for agents", "automation"],
  ["Agents mogen de terminal, browser en pull requests van Nook gebruiken", "Agents may use Nook's terminal, browser and pull requests", "automation"],
  ["Ook voor agents buiten Nook", "Also for agents outside Nook", "automation"],
  ["Project", "Project", "projects"],
  ["Gearchiveerde projecten", "Archived projects", "projects"],
  ["Nieuw project uit een map", "New project from a folder", "projects"],
  ["Gevolgde pull requests", "Watched pull requests", "pullRequests"],
  ["Chat-apps", "Chat apps", "chats"],
  ["Jouw koppelingen", "Your connections", "connections"],
  ["Op dit apparaat", "On this device", "connections"],
  ["Muziek", "Music", "connections"],
  ["Songteksten online opzoeken", "Look up lyrics online", "connections"],
  ["Telefoon", "Phone", "iphone"],
  ["Companion op je telefoon", "Companion on your phone", "iphone"],
  ["Gekoppelde telefoons", "Paired phones", "iphone"],
  ["Buiten de deur", "Away from home", "iphone"],
  ["Meldingen op je telefoon", "Notifications on your phone", "iphone"],
  ["Pushmeldingen", "Push notifications", "iphone"],
  ["Alleen als ik niet bij de computer ben", "Only when I'm away from the computer", "iphone"],
  ["Bereik deze computer buiten de deur", "Reach this computer away from home", "iphone"],
  ["Relay", "Relay", "iphone"],
  ["Houd deze computer wakker", "Keep this computer awake", "iphone"],
  ["Schermtekst", "Screen text", "privacy"],
  ["Machtigingen", "Permissions", "privacy"],
  ["Gekoppelde accounts en diensten", "Linked accounts and services", "privacy"],
  ["Logboek", "Log", "privacy"],
  ["Updates", "Updates", "maintenance"],
  ["Automatisch zoeken", "Check automatically", "maintenance"],
  ["Kanaal", "Channel", "maintenance"],
  ["Diagnose", "Diagnostics", "maintenance"],
  ["Agentverkeer bewaren", "Keep agent traffic", "maintenance"],
  ["Diagnose exporteren", "Export diagnostics", "maintenance"],
  ["OpenTelemetry-export", "OpenTelemetry export", "maintenance"],
  ["Protocol voor agents", "Protocol for agents", "maintenance"],
  ["Gegevens", "Data", "maintenance"],
  ["Gegevensmap", "Data folder", "maintenance"],
  ["Caches", "Caches", "maintenance"],
  ["Instellingen", "Settings", "maintenance"],
  ["Standaardinstellingen", "Default settings", "maintenance"],
  ["Versies", "Versions", "maintenance"],
  ["Energie", "Energy", "maintenance"],
  ["Versie", "Version", "about"],
  ["Juridisch", "Legal", "about"],
  ["Licentie", "License", "about"],
  ["Opensourcevermeldingen", "Open source notices", "about"],
];

export interface SettingHit { title: string; section: SettingsSectionId }

/** The settings whose on-screen name has every word typed, in the order of the sidebar; `shown` drops the subjects
 *  this platform leaves out. */
export function settingHits(query: string, shown: (id: SettingsSectionId) => boolean): SettingHit[] {
  if (!query.trim()) return [];
  const seen = new Set<string>();
  const hits: SettingHit[] = [];
  for (const [nl, en, section] of SETTINGS_INDEX) {
    const title = tr(nl, en);
    const key = `${section}:${title}`;
    if (seen.has(key) || !shown(section) || !matchesSearch(query, title)) continue;
    seen.add(key);
    hits.push({ title, section });
  }
  return hits;
}

/** The setting a search led to; a fold whose rows include it opens itself, and the page lights it. */
class SettingsHighlight {
  title = $state<string | null>(null);
}
export const settingsHighlight = new SettingsHighlight();

/** The element on a page that carries a setting's name: a heading, a fold's head or a row's own label. */
function labelled(root: HTMLElement, title: string): HTMLElement | null {
  for (const el of root.querySelectorAll<HTMLElement>("h3, .fold-head .name, .row span, .row label, summary")) {
    const first = [...el.childNodes].find((n) => n.nodeType === Node.TEXT_NODE && n.textContent?.trim());
    if (first?.textContent?.trim() === title) return el;
  }
  return null;
}

/** Scrolls the page to the setting a search led to and lights its row (or heading) for 1.6 s. */
export function lightSetting(root: HTMLElement, title: string): boolean {
  const label = labelled(root, title);
  if (!label) return false;
  const target = label.closest<HTMLElement>(".row, .fold") ?? label;
  const reduce = typeof matchMedia !== "undefined" && matchMedia("(prefers-reduced-motion: reduce)").matches;
  target.scrollIntoView({ block: "center", behavior: reduce ? "auto" : "smooth" });
  target.classList.add("setting-lit");
  setTimeout(() => target.classList.remove("setting-lit"), 1600);
  return true;
}
