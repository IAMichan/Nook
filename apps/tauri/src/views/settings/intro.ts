// What each page and subject of Settings holds, in one line under its name (`SettingsPageIntro` on the Mac:
// `pageSubtitle`, `subtitle` and `info` of `SettingsSection`). The wording is the Mac's (I18n+SettingsPages,
// I18n+SettingsLayout), with "this computer" where the Mac says "this Mac"; Gamer Mode is Windows' own page.
import { tr } from "../../lib/i18n.svelte";
import type { SettingsSectionId } from "../../lib/settings-pages";

/** The one line under a subject's name: on its page, and under the tab bar for a subject that is not its page's first. */
export function sectionSubtitle(section: SettingsSectionId): string {
  switch (section) {
    case "start": return tr("Wat werkt, en wat jou nog nodig heeft", "What works, and what still needs you");
    case "general": return tr("Talen, de sessielijst en bevestigingen", "Languages, the session list and confirmations");
    case "notch": return tr("Waar Nook staat, en hoe hij zich gedraagt in vergaderingen", "Where Nook shows, and how it behaves in meetings");
    case "appearance": return tr("Hoe Nook eruitziet, en Nook als maatje", "How Nook looks, and Nook as a buddy");
    case "notifications": return tr("Hoe meldingen verschijnen, en wie ze mag sturen", "How notices show, and who may send them");
    case "notificationApps": return tr("Welke apps, agents en chats je mogen melden", "Which apps, agents and chats may notify you");
    case "sound": return tr("Geluiden, voorlezen, “Hé Nook” en spraakherkenning", "Sounds, reading aloud, “Hey Nook” and speech recognition");
    case "shortcuts": return tr("Toetsen die overal werken en in het paneel", "Keys that work anywhere and in the panel");
    case "brain": return tr("Met welke AI Nook denkt", "Which AI Nook thinks with");
    case "assistant": return tr("Wat Nook ziet en uit zichzelf doet", "What Nook sees and does by itself");
    case "memory": return tr("Wat Nook over je onthoudt", "What Nook remembers about you");
    case "instructions": return tr("Antwoordstijl, opgeslagen prompts, ruimtes en wat het model leest", "Answer style, saved prompts, spaces and what the model reads");
    case "autocomplete": return tr("Zinnen aanvullen terwijl je typt, in elke app", "Complete sentences as you type, in any app");
    case "autocompleteApps": return tr("Waar aanvullen aan of uit staat, en instellingen per app", "Where completing is on or off, and per-app settings");
    case "autocompleteStyle": return tr("Wat het model leest, je eigen woorden en extra's", "What the model reads, your own words and extras");
    case "autocompletePlayground": return tr("Probeer aanvullen zonder Instellingen te verlaten", "Try completing without leaving Settings");
    case "autocompleteStats": return tr("Wat aanvullen je bespaarde", "What completing saved you");
    case "dictation": return tr("Praten in plaats van typen, in elke app", "Talk instead of typing, in any app");
    case "agents": return tr("Je agents koppelen, en hun accounts", "Linking your agents and their accounts");
    case "skills": return tr("De skills die je agents lezen, voor jezelf en per project", "The skills your agents read, for yourself and per project");
    case "usage": return tr("Wat je agents verbruikten, en hun limieten", "What your agents used, and their limits");
    case "sessions": return tr("Waarmee een nieuwe sessie start, en hoe sessies werken", "What a new session starts with, and how sessions behave");
    case "worktrees": return tr("Waar nieuwe worktrees komen en wanneer Nook ze opruimt", "Where new worktrees go and when Nook cleans them up");
    case "projects": return tr("Wat één project zelf instelt", "What one project sets for itself");
    case "pullRequests": return tr("De repositories die Nook volgt, en hoe pull requests gevolgd worden", "The repositories Nook watches, and how pull requests are watched");
    case "openIn": return tr("Waar de bestanden en links van een sessie openen", "Where a session's files and links open");
    case "archive": return tr("Gearchiveerde sessies en gesprekken", "Archived sessions and conversations");
    case "automation": return tr("Geplande taken, en wat agents van Nook mogen gebruiken", "Scheduled tasks, and what agents may use of Nook");
    case "chats": return tr("WhatsApp, Telegram, Slack en de rest, en hoe chats gelezen worden", "WhatsApp, Telegram, Slack and the rest, and how chats are read");
    case "connections": return tr("Online diensten, je eigen servers en de apps op deze computer", "Online services, your own servers and the apps on this computer");
    case "iphone": return tr("Nook op je iPhone, ook buitenshuis", "Nook on your iPhone, also away from home");
    case "machines": return tr("Computers waar je agents via SSH op werken", "Computers your agents work on over SSH");
    case "privacy": return tr("Wat een cloud-AI mag zien, en vergeten wat Nook zag", "What a cloud AI may see, and forgetting what Nook saw");
    case "permissions": return tr("De machtigingen van de computer en de accounts die Nook bereikt", "The computer's permissions and the accounts Nook can reach");
    case "activityLog": return tr("Wat Nook deed, en wanneer", "What Nook did, and when");
    case "maintenance": return tr("Updates, achtergrondactiviteit en diagnose", "Updates, background activity and diagnostics");
    case "about": return tr("Versie, broncode en licentie", "Version, source code and license");
    case "games": return tr("Nook houdt zich stil terwijl je speelt", "Nook keeps quiet while you play");
  }
}

/** The line under a page's name: for a page of several subjects what they hold together, else its subject's line. */
export function pageSubtitle(page: SettingsSectionId, several: boolean): string {
  switch (several || page === "privacy" ? page : null) {
    case "general": return tr("Taal, waar Nook verschijnt, en bevestigingen", "Language, where Nook shows, and confirmations");
    case "notifications": return tr("Hoe en van wie Nook je meldt, en hoe het klinkt", "How and from whom Nook notifies you, and how it sounds");
    case "assistant": return tr("Wat Nook voor je doet, wat het onthoudt en wat het volgt", "What Nook does for you, what it remembers and what it follows");
    case "autocomplete": return tr("Suggesties terwijl je typt in elke app, en dicteren", "Suggestions as you type in any app, and dictation");
    case "agents": return tr("Gekoppelde agents en accounts, hun skills, en wat ze kosten", "Linked agents and accounts, their skills, and what they cost");
    case "sessions": return tr("Hoe sessies starten en werken, waar ze draaien en openen, en het archief", "How sessions start and behave, where they work and open, and the archive");
    case "projects": return tr("Wat elk project zelf instelt, en hoe pull requests gevolgd en geschreven worden", "What each project sets for itself, and how pull requests are watched and written");
    case "iphone": return tr("Nook op je telefoon, en de machines waar je agents op werken", "Nook on your phone, and the machines your agents work on");
    case "privacy": return tr("Wat Nook mag zien en versturen, en wat het deed", "What Nook may see and send, and what it did");
    case "maintenance": return tr("Updates, energie, diagnose en over Nook", "Updates, energy, diagnostics and about Nook");
    default: return sectionSubtitle(page);
  }
}

/** How a subject treats your data, in small type under the intro; null for most. */
export function sectionInfo(section: SettingsSectionId): string | null {
  if (section === "memory") return tr("Opgeslagen in nook.sqlite op deze computer. Een externe AI krijgt alleen de paar herinneringen die een vraag nodig heeft, nooit vergrendelde; wachtwoorden en codes worden nooit onthouden.", "Stored in nook.sqlite on this computer. An external AI only gets the few memories a question needs, never locked ones; passwords and codes are never remembered.");
  if (section !== "chats" && section !== "connections") return null;
  return tr("Verbind een dienst en Nook kan er meteen mee werken. Inloggen gebeurt op de site van de dienst zelf; sleutels en tokens blijven in de kluis van je systeem.", "Connect a service and Nook can work with it right away. You sign in on the service's own site; keys and tokens stay in your system's keychain.");
}
