// The Chats tab's list as on the Mac (`ChatsEntry`, `ChatsView`, `ChatsGroup`, `ChatsListKind`): one row per chat of
// every chat app, the views by where a chat stands, the groups by when it last moved, and the Chats / Status / Channels
// tabs. Each chat app only translates its own data into a `ChatEntry` (WhatsApp in `whatsAppEntry`), so a view or a fix
// here reaches every app at once.
import { locale as appLocale, tr } from "./i18n.svelte";
import type { ChatReaction, ChatReadState, ChatSummary, InboxMessage, WhatsAppConversation, WhatsAppMessage, WhatsAppReceipt } from "./connectors";

/** Where a chat shows: between the chats, under Status (a contact's status updates) or under Channels. */
export type ChatListKind = "chats" | "status" | "channels";
/** The sidebar's views (`ChatsView`): every chat, something new, read in Nook only (the app still holds it unread, so
 *  the people who wrote do not see it), read everywhere. */
export type ChatView = "all" | "unread" | "readInNook" | "read";
/** Where a chat stands (`ChatReadState`). */
export type ReadMark = "unread" | "readInNook" | "read";

export interface ChatEntry {
  /** The chat's id in its app (a WhatsApp JID, the helper's chat id); what the app's own steps take. */
  id: string;
  /** The shared inbox's key (`app#id`): what Nook's own steps take (read, unread, pin, remove, send). */
  key: string;
  /** The chat app's id ("whatsapp", "telegram"); its name and icon come from `chatApps`. */
  app: string;
  name: string;
  isGroup: boolean;
  listKind: ChatListKind;
  /** When it last moved, or null when its app did not date it. */
  last: Date | null;
  /** The newest message as the row shows it ("Anna: see you", "Photo"). */
  preview: string;
  /** Your own newest message: how far it got (its ticks in front of the preview). */
  ticks: WhatsAppReceipt | null;
  unread: number;
  read: ReadMark;
  /** Whether the newest message is yours. */
  lastIsMine: boolean;
  /** The account it came in on, while an app has more than one. */
  account: string | null;
  /** Nook can write in it from here. */
  sends: boolean;
  /** Muted in its own app. */
  mutedInApp: boolean;
}

/** The chat apps Nook can read on this computer, by id: their name and the domain their icon comes from. WhatsApp
 *  through its gateway; the others through Nook's chat helper (nook-chatd). */
export const chatApps: Record<string, { name: string; domain: string }> = {
  whatsapp: { name: "WhatsApp", domain: "whatsapp.com" },
  telegram: { name: "Telegram", domain: "telegram.org" },
  signal: { name: "Signal", domain: "signal.org" },
  messenger: { name: "Messenger", domain: "messenger.com" },
  instagram: { name: "Instagram", domain: "instagram.com" },
  x: { name: "X", domain: "x.com" },
  linkedin: { name: "LinkedIn", domain: "linkedin.com" },
  slack: { name: "Slack", domain: "slack.com" },
  teams: { name: "Teams", domain: "teams.microsoft.com" },
  discord: { name: "Discord", domain: "discord.com" },
  googlechat: { name: "Google Chat", domain: "chat.google.com" },
  snapchat: { name: "Snapchat", domain: "snapchat.com" },
  viber: { name: "Viber", domain: "viber.com" },
  wechat: { name: "WeChat", domain: "wechat.com" },
  line: { name: "LINE", domain: "line.me" },
  skype: { name: "Skype", domain: "skype.com" },
  element: { name: "Element", domain: "element.io" },
  threema: { name: "Threema", domain: "threema.ch" },
  wire: { name: "Wire", domain: "wire.com" },
  messages: { name: "Messages", domain: "apple.com" },
};

export const appName = (app: string) => chatApps[app]?.name ?? app;

/** The inbox's key of a WhatsApp chat (`whatsapp::Inbox::key`). */
export const whatsAppKey = (jid: string) => `whatsapp#${jid}`;

const listKindOf = (kind: string | null | undefined): ChatListKind => (kind === "status" ? "status" : kind === "channel" ? "channels" : "chats");
const readMark = (r: ChatReadState | undefined, unread: number): ReadMark => (unread > 0 ? "unread" : r?.state === "readInNook" ? "readInNook" : "read");
const dated = (value: string | undefined | null): Date | null => {
  const d = new Date(value ?? "");
  return Number.isNaN(d.getTime()) || d.getTime() <= 0 ? null : d;
};
function previewOf(m: { text: string; fromMe: boolean; deleted?: boolean } | undefined, sender: string, isGroup: boolean, media: string): string {
  if (!m) return "";
  const text = m.deleted ? tr("Dit bericht is verwijderd", "This message was deleted") : m.text || media;
  return isGroup && !m.fromMe && sender ? `${sender}: ${text}` : text;
}

/** A WhatsApp chat as a row of the list; its read state comes from the shared inbox when it has the chat. */
export function whatsAppEntry(c: WhatsAppConversation, inbox?: ChatSummary, sends = true): ChatEntry {
  const m = c.messages[c.messages.length - 1];
  const media = m && m.media.kind !== "none" ? mediaWord(m.media.kind) : "";
  return {
    id: c.id,
    key: whatsAppKey(c.id),
    app: "whatsapp",
    name: c.name,
    isGroup: c.isGroup,
    listKind: listKindOf(c.kind),
    last: dated(m?.date ?? c.lastActivity),
    preview: previewOf(m, m?.senderName ?? "", c.isGroup, media),
    ticks: m?.fromMe ? m.receipt ?? null : null,
    unread: c.unread,
    read: readMark(inbox?.read, c.unread),
    lastIsMine: !!m?.fromMe,
    account: inbox?.account ?? null,
    sends,
    mutedInApp: false,
  };
}

/** Any other app's chat from the shared inbox as a row of the list. */
export function inboxEntry(s: ChatSummary): ChatEntry {
  const m = s.last ?? undefined;
  const isGroup = s.kind === "group" || s.members > 1;
  const unread = s.read.state === "unread" ? s.read.count : 0;
  const media = m?.media && m.media.kind !== "none" ? mediaWord(m.media.kind) : "";
  return {
    id: s.key.slice(s.key.indexOf("#") + 1),
    key: s.key,
    app: s.app,
    name: s.name,
    isGroup,
    listKind: listKindOf(s.kind),
    last: dated(s.activity),
    preview: previewOf(m, m?.sender ?? "", isGroup, media),
    ticks: m?.fromMe ? m.receipt ?? null : null,
    unread,
    read: readMark(s.read, unread),
    lastIsMine: !!m?.fromMe,
    account: s.account,
    sends: s.sends,
    mutedInApp: s.mutedInApp,
  };
}

/** One message as a bubble, the same for every app (`ChatBubble`). */
export interface Bubble {
  id: string;
  sender: string;
  text: string;
  date: string;
  fromMe: boolean;
  media: { kind: WhatsAppMessage["media"]["kind"]; name?: string | null };
  receipt: WhatsAppReceipt | null;
  edited: boolean;
  deleted: boolean;
  replyTo: string | null;
  reactions: ChatReaction[];
}

export const bubbleOfWhatsApp = (m: WhatsAppMessage): Bubble => ({
  id: m.id, sender: m.senderName, text: m.text, date: m.date, fromMe: m.fromMe, media: m.media, receipt: m.receipt ?? null, edited: false, deleted: false, replyTo: null, reactions: [],
});

export const bubbleOfInbox = (m: InboxMessage): Bubble => ({
  id: m.id, sender: m.sender, text: m.text, date: m.date, fromMe: m.fromMe, media: m.media ?? { kind: "none" }, receipt: m.receipt ?? null,
  edited: !!m.edited, deleted: !!m.deleted, replyTo: m.replyTo ?? null, reactions: m.reactions ?? [],
});

/** The quick reactions over a message's menu, as the phone's chat apps offer them. */
export const QUICK_REACTIONS = ["👍", "❤️", "😂", "😮", "😢", "🙏"];

/** The emoji under the composer's smiley (`ChatEmojiButton`): the ones you used most first, then a common set. */
export const COMMON_EMOJI = ["😀", "😂", "🥲", "😊", "😍", "😘", "😎", "🤔", "😅", "😭", "😴", "🙄", "😬", "🤗", "🥳", "😇",
  "👍", "👎", "👏", "🙌", "🙏", "💪", "👋", "🤝", "❤️", "🧡", "💛", "💚", "💙", "💜", "🔥", "✨",
  "🎉", "🎂", "☕", "🍕", "🍻", "⚽", "🚗", "✈️", "🏠", "📅", "✅", "❌", "⚠️", "💡", "📎", "👀"];
const FREQUENT = "chats.emoji.frequent";

/** The emoji you used, most used first (`ChatEmojiFrequency`). */
export function frequentEmoji(): string[] {
  try {
    const counts = JSON.parse(localStorage.getItem(FREQUENT) ?? "{}") as Record<string, number>;
    return Object.entries(counts).sort((a, b) => b[1] - a[1]).map(([e]) => e).slice(0, 16);
  } catch {
    return [];
  }
}

export function usedEmoji(emoji: string) {
  try {
    const counts = JSON.parse(localStorage.getItem(FREQUENT) ?? "{}") as Record<string, number>;
    counts[emoji] = (counts[emoji] ?? 0) + 1;
    localStorage.setItem(FREQUENT, JSON.stringify(counts));
  } catch {
    // Not remembered.
  }
}

/** The "@Name" being typed at the end of the text before the cursor, for the list of a group's people (`ChatTags`). */
export function typingTag(text: string): string | null {
  const m = /(?:^|\s)@([^\s@]{0,30})$/.exec(text);
  return m ? m[1] : null;
}

/** The text with the "@…" being typed replaced by "@Name ". */
export function insertTag(text: string, name: string): string {
  return text.replace(/(^|\s)@([^\s@]{0,30})$/, `$1@${name} `);
}

function mediaWord(kind: string): string {
  switch (kind) {
    case "image": return tr("Foto", "Photo");
    case "video": return tr("Video", "Video");
    case "audio":
    case "voice": return tr("Spraakbericht", "Voice message");
    case "document": return tr("Document", "Document");
    case "sticker": return tr("Sticker", "Sticker");
    case "location": return tr("Locatie", "Location");
    case "contact": return tr("Contact", "Contact");
    default: return tr("Bijlage", "Attachment");
  }
}

export function viewTitle(view: ChatView): string {
  switch (view) {
    case "all": return tr("Alle chats", "All chats");
    case "unread": return tr("Nieuw", "New");
    case "readInNook": return tr("Alleen in Nook", "Only in Nook");
    case "read": return tr("Gelezen", "Read");
  }
}

export function kindTitle(kind: ChatListKind): string {
  switch (kind) {
    case "chats": return tr("Chats", "Chats");
    case "status": return tr("Status", "Status");
    case "channels": return tr("Kanalen", "Channels");
  }
}

export function shows(view: ChatView, e: ChatEntry): boolean {
  return view === "all" || e.read === view;
}

/** What the list shows: the chosen view, app, account and tab, matching the search by name or newest message, newest
 *  first. */
export function shown(all: ChatEntry[], o: { view: ChatView; app: string | null; account?: string | null; kind: ChatListKind; query: string }): ChatEntry[] {
  const needle = o.query.trim().toLowerCase();
  return all
    .filter((e) => e.listKind === o.kind && (!o.app || e.app === o.app) && (!o.account || e.account === o.account))
    .filter((e) => (needle ? `${e.name}\n${e.preview}`.toLowerCase().includes(needle) : shows(o.view, e)))
    .sort((a, b) => (b.last?.getTime() ?? 0) - (a.last?.getTime() ?? 0));
}

/** The list's groups (`ChatsGroup`): the chats you pinned on top, then by when a chat last moved. */
export type ChatGroup = "pinned" | "today" | "yesterday" | "week" | "month" | "earlier";

export function groupTitle(g: ChatGroup): string {
  switch (g) {
    case "pinned": return tr("Vastgezet", "Pinned");
    case "today": return tr("Vandaag", "Today");
    case "yesterday": return tr("Gisteren", "Yesterday");
    case "week": return tr("Deze week", "This week");
    case "month": return tr("Deze maand", "This month");
    case "earlier": return tr("Eerder", "Earlier");
  }
}

const DAY = 86_400_000;
const startOfDay = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate());

export function groupOf(last: Date | null, now: Date): ChatGroup {
  if (!last) return "earlier";
  const today = startOfDay(now).getTime();
  const t = last.getTime();
  if (t >= today) return "today";
  if (t >= today - DAY) return "yesterday";
  if (t >= today - 7 * DAY) return "week";
  if (t >= today - 30 * DAY) return "month";
  return "earlier";
}

/** The rows in their groups, in order, pinned ones first; empty groups are left out. */
export function sections(entries: ChatEntry[], now: Date, pinned: string[] = []): { group: ChatGroup; entries: ChatEntry[] }[] {
  const out: { group: ChatGroup; entries: ChatEntry[] }[] = [];
  const pins = entries.filter((e) => pinned.includes(e.key));
  if (pins.length) out.push({ group: "pinned", entries: pins });
  for (const e of entries) {
    if (pinned.includes(e.key)) continue;
    const g = groupOf(e.last, now);
    const tail = out[out.length - 1];
    if (tail?.group === g) tail.entries.push(e);
    else out.push({ group: g, entries: [e] });
  }
  return out;
}

/** "14:03" today, else the day: "Yesterday", the weekday within a week, else "12 Oct" (`NookDates.clockOrDay`). */
export function clockOrDay(date: Date | null, now: Date, locale: string = appLocale()): string {
  if (!date) return "";
  const today = startOfDay(now).getTime();
  const t = date.getTime();
  if (t >= today && t < today + DAY) return `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
  if (t >= today - DAY && t < today) return tr("Gisteren", "Yesterday");
  if (t >= today - 6 * DAY && t < today) return date.toLocaleDateString(locale, { weekday: "long" });
  return date.toLocaleDateString(locale, { day: "numeric", month: "short" });
}

/** A day line between the messages of a chat: "Today", "Yesterday", the weekday, or the date. */
export function dayLabel(date: Date, now: Date, locale: string = appLocale()): string {
  const today = startOfDay(now).getTime();
  const t = startOfDay(date).getTime();
  if (t === today) return tr("Vandaag", "Today");
  if (t === today - DAY) return tr("Gisteren", "Yesterday");
  if (t > today - 7 * DAY) return date.toLocaleDateString(locale, { weekday: "long" });
  return date.toLocaleDateString(locale, { day: "numeric", month: "long", year: date.getFullYear() === now.getFullYear() ? undefined : "numeric" });
}

/** Each person's own color, the same every time (`ChatPersonTint`): a theme variable's name. */
const tints = ["--mint", "--blue", "--violet", "--music"];
export function personTint(name: string): string {
  let hash = 2_166_136_261;
  for (const byte of new TextEncoder().encode(name.toLowerCase())) {
    hash ^= byte;
    hash = Math.imul(hash, 16_777_619) >>> 0;
  }
  return `var(${tints[hash % tints.length]})`;
}
