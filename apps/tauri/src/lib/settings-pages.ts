// The layout of Settings, as on the Mac (`SettingsSection` in apps/macos/App/Settings/SettingsView.swift): pages in five
// groups (Nook, Intelligence, Agents, Connect, System; the first and the last without a heading), and a page that holds
// several subjects shows them behind a tab bar (`SettingsPartTabs`). A subject is what you open: a sidebar row opens its
// page's first subject, a button elsewhere opens a subject by id (`settingsSection`), and the tab bar switches between
// the subjects of one page.
//
// The Tauri app follows the Mac's pages and names. Where it has no content for a Mac subject yet (Notifications per
// app, Editor & browser, the privacy parts), the subject is left out until
// its item in docs/WINDOWS-PARITY.md lands; Gamer Mode is a Tauri-first page in the Nook group.
import { tr } from "./i18n.svelte";

export const settingsGroups = ["nook", "intelligence", "agents", "connect", "system"] as const;
export type SettingsGroupId = (typeof settingsGroups)[number];

/** Every subject, in the order of the sidebar and its pages' tab bars. */
export const settingsSections = [
  "start", "general", "notch", "appearance", "notifications", "notificationApps", "sound", "shortcuts", "games",
  "brain", "assistant", "memory", "instructions",
  "autocomplete", "autocompleteApps", "autocompleteStyle", "autocompletePlayground", "autocompleteStats", "dictation",
  "agents", "skills", "usage", "sessions", "worktrees", "openIn", "archive", "automation", "projects", "pullRequests",
  "chats", "connections", "iphone", "machines", "privacy", "permissions", "activityLog",
  "maintenance", "about",
] as const;
export type SettingsSectionId = (typeof settingsSections)[number];

/** The sidebar pages per group, each with the subjects it holds (its own first). */
export const settingsPages: Record<SettingsGroupId, { page: SettingsSectionId; parts: SettingsSectionId[] }[]> = {
  nook: [
    { page: "start", parts: ["start"] },
    { page: "general", parts: ["general", "notch"] },
    { page: "appearance", parts: ["appearance"] },
    { page: "notifications", parts: ["notifications", "notificationApps", "sound"] },
    { page: "shortcuts", parts: ["shortcuts"] },
    { page: "games", parts: ["games"] },
  ],
  intelligence: [
    { page: "brain", parts: ["brain"] },
    { page: "assistant", parts: ["assistant", "memory", "instructions"] },
    { page: "autocomplete", parts: ["autocomplete", "autocompleteApps", "autocompleteStyle", "autocompletePlayground", "autocompleteStats", "dictation"] },
  ],
  agents: [
    { page: "agents", parts: ["agents", "skills", "usage"] },
    { page: "sessions", parts: ["sessions", "worktrees", "openIn", "archive"] },
    { page: "automation", parts: ["automation"] },
    { page: "projects", parts: ["projects", "pullRequests"] },
  ],
  connect: [
    { page: "chats", parts: ["chats"] },
    { page: "connections", parts: ["connections"] },
    { page: "iphone", parts: ["iphone", "machines"] },
    { page: "privacy", parts: ["privacy", "permissions", "activityLog"] },
  ],
  system: [
    { page: "maintenance", parts: ["maintenance", "about"] },
  ],
};

/** The sidebar page a subject lives on. */
export function settingsHost(section: SettingsSectionId): SettingsSectionId {
  for (const group of settingsGroups) for (const p of settingsPages[group]) if (p.parts.includes(section)) return p.page;
  return section;
}

/** The subjects of the page a subject lives on, in order. */
export function settingsParts(section: SettingsSectionId): SettingsSectionId[] {
  const host = settingsHost(section);
  for (const group of settingsGroups) for (const p of settingsPages[group]) if (p.page === host) return p.parts;
  return [section];
}

/** The group of the page a subject lives on. */
export function settingsGroup(section: SettingsSectionId): SettingsGroupId {
  const host = settingsHost(section);
  return settingsGroups.find((g) => settingsPages[g].some((p) => p.page === host)) ?? "nook";
}

/** Other names a button elsewhere may use, and the page ids of earlier versions (remembered in localStorage). */
const sectionAliases: Record<string, SettingsSectionId> = {
  overview: "start", accounts: "connections", voice: "sound", companion: "iphone", gamer: "games",
  look: "appearance", theme: "appearance", keys: "shortcuts", keybindings: "shortcuts", updates: "maintenance",
  typing: "autocomplete", flow: "dictation", system: "maintenance", devices: "iphone", phone: "iphone", ssh: "machines",
  services: "connections", bar: "notch", quiet: "notch",
};

/** The subject a stored or requested name stands for; the Overview for anything unknown. */
export function settingsSection(value: string | null | undefined): SettingsSectionId {
  if (!value) return "start";
  if ((settingsSections as readonly string[]).includes(value)) return value as SettingsSectionId;
  return Object.prototype.hasOwnProperty.call(sectionAliases, value) ? sectionAliases[value] : "start";
}

/** The heading over a group in the sidebar; the first and the last stand on their own. */
export function groupTitle(group: SettingsGroupId): string | null {
  switch (group) {
    case "nook": case "system": return null;
    case "intelligence": return tr("Intelligentie", "Intelligence");
    case "agents": return tr("Agents", "Agents");
    case "connect": return tr("Koppelingen", "Connections");
  }
}

/** A subject's own name: on its tab, and in the sidebar for a page of one subject. */
export function sectionTitle(section: SettingsSectionId): string {
  switch (section) {
    case "start": return tr("Overzicht", "Overview");
    case "general": return tr("Algemeen", "General");
    case "notch": return tr("Balk en vensters", "Bar & windows");
    case "appearance": return tr("Uiterlijk", "Appearance");
    case "notifications": return tr("Meldingen", "Notifications");
    case "notificationApps": return tr("Meldingen per app", "Notifications per app");
    case "sound": return tr("Geluid en stem", "Sound & voice");
    case "shortcuts": return tr("Sneltoetsen", "Shortcuts");
    case "games": return "Gamer Mode";
    case "brain": return tr("Brein", "Brain");
    case "assistant": return tr("Assistent", "Assistant");
    case "memory": return tr("Geheugen", "Memory");
    case "instructions": return tr("Instructies", "Instructions");
    case "autocomplete": return tr("Aanvullen", "Autocomplete");
    case "autocompleteApps": return tr("Apps en sites", "Apps and sites");
    case "autocompleteStyle": return tr("Stijl en context", "Style and context");
    case "autocompletePlayground": return tr("Proefveld", "Playground");
    case "autocompleteStats": return tr("Statistieken", "Statistics");
    case "dictation": return tr("Dicteren", "Dictation");
    case "agents": return "Coding agents";
    case "skills": return tr("Skills", "Skills");
    case "usage": return tr("Gebruik en kosten", "Usage & costs");
    case "sessions": return tr("Sessies", "Sessions");
    case "worktrees": return tr("Worktrees", "Worktrees");
    case "openIn": return tr("Editor en browser", "Editor & browser");
    case "archive": return tr("Archief", "Archive");
    case "automation": return tr("Automatisering", "Automation");
    case "projects": return tr("Projecten", "Projects");
    case "pullRequests": return tr("Pull requests", "Pull requests");
    case "chats": return tr("Chat-apps", "Chat apps");
    case "connections": return tr("Diensten", "Services");
    case "iphone": return "Companion";
    case "machines": return tr("Machines", "Machines");
    case "privacy": return tr("Privacyniveau", "Privacy level");
    case "permissions": return tr("Toegang", "Access");
    case "activityLog": return tr("Logboek", "Activity log");
    case "maintenance": return tr("Onderhoud", "Maintenance");
    case "about": return tr("Over Nook", "About Nook");
  }
}

/** A page's name in the sidebar and over the page: its first subject's, unless the page holds more than that. */
export function pageTitle(page: SettingsSectionId): string {
  switch (page) {
    case "autocomplete": return tr("Typen", "Typing");
    case "iphone": return tr("Apparaten", "Devices");
    case "privacy": return tr("Privacy", "Privacy");
    case "maintenance": return tr("Systeem", "System");
    case "projects": return tr("Projecten & pull requests", "Projects & pull requests");
    default: return sectionTitle(page);
  }
}

/** Where a subject is, for a search result or the bar over the page: its page, and its own name when it is a part. */
export function sectionTrail(section: SettingsSectionId): string {
  const host = settingsHost(section);
  return host === section ? pageTitle(host) : `${pageTitle(host)} › ${sectionTitle(section)}`;
}

/**
 * The line icon in front of each page in the sidebar and on its tab, matching the Mac's
 * `SettingsSection.sidebarSymbol` mapped to Lucide icons (`NookIcon`).
 */
export const sectionIcons: Record<SettingsSectionId, string> = {
  start: "house", general: "settings", notch: "laptop", appearance: "palette", notifications: "bell", notificationApps: "bell-dot", sound: "volume-2",
  shortcuts: "keyboard", games: "gamepad-2", brain: "brain", assistant: "sparkles", memory: "library", instructions: "list-checks",
  autocomplete: "text-cursor", autocompleteApps: "layout-grid", autocompleteStyle: "type", autocompletePlayground: "text-cursor-input",
  autocompleteStats: "trending-up", dictation: "mic", agents: "terminal", skills: "book", usage: "chart-column", sessions: "messages-square",
  worktrees: "folder", openIn: "external-link", archive: "archive", automation: "calendar-clock", projects: "folder-cog", pullRequests: "git-branch",
  chats: "messages-square", connections: "user-check", iphone: "monitor-smartphone", machines: "server",
  privacy: "hand", permissions: "shield-check", activityLog: "list", maintenance: "wrench", about: "info",
};

/** Sidebar line icon for a Settings section. */
export function sectionIcon(section: SettingsSectionId): string {
  return sectionIcons[section];
}

/**
 * Tile icons for `SettingsTile`, matching the Mac's `SettingsSection.tileSymbol`: mostly identical to
 * `sectionIcons`, with the four section-specific tile glyphs where the Mac differs from its sidebar glyph.
 */
export const sectionTileIcons: Record<SettingsSectionId, string> = {
  ...sectionIcons,
  autocomplete: "keyboard",
  dictation: "audio-waveform",
  automation: "history",
  iphone: "smartphone",
};

/** Tile icon for `SettingsTile` given a Settings section. */
export function sectionTileIcon(section: SettingsSectionId): string {
  return sectionTileIcons[section];
}
