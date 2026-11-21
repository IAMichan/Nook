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

export interface MessageReader {
  name: string;
  receipt: WhatsAppReceipt;
  date?: string | null;
}

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
  /** The person's phone number or address, when known (used for People matching). */
  handle?: string | null;
  /** People currently typing in this chat (live ephemeral state). */
  typing?: string[];
}

type ExtendedSummary = ChatSummary & { handle?: string | null; typing?: string[] };
type ExtendedInboxMessage = InboxMessage & { readAt?: string | null; readBy?: string[]; readers?: MessageReader[] };

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

function whatsAppHandle(jid: string, isGroup: boolean): string | null {
  if (isGroup || !jid.endsWith("@s.whatsapp.net")) return null;
  const digits = jid.slice(0, jid.indexOf("@")).replace(/\D+/g, "");
  return digits.length >= 7 ? `+${digits}` : null;
}

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
  const ext = inbox as ExtendedSummary | undefined;
  return {
    id: c.id,
    key: whatsAppKey(c.id),
    app: "whatsapp",
    name: c.name,
    isGroup: c.isGroup,
    listKind: listKindOf(c.kind),
    last: dated(m?.date ?? c.lastActivity),
    preview: previewOf(m, m?.senderName ?? "", c.isGroup, media),
    ticks: m?.fromMe ? m.receipt ?? "sent" : null,
    unread: c.unread,
    read: readMark(inbox?.read, c.unread),
    lastIsMine: !!m?.fromMe,
    account: inbox?.account ?? null,
    sends,
    mutedInApp: false,
    handle: ext?.handle ?? whatsAppHandle(c.id, c.isGroup),
    typing: ext?.typing ?? [],
  };
}

/** Any other app's chat from the shared inbox as a row of the list. */
export function inboxEntry(s: ChatSummary): ChatEntry {
  const ext = s as ExtendedSummary;
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
    ticks: m?.fromMe ? m.receipt ?? "sent" : null,
    unread,
    read: readMark(s.read, unread),
    lastIsMine: !!m?.fromMe,
    account: s.account,
    sends: s.sends,
    mutedInApp: s.mutedInApp,
    handle: ext.handle ?? null,
    typing: ext.typing ?? [],
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
  versions: { text: string; replaced: string }[];
  readAt?: string | null;
  readBy?: string[];
  readers?: MessageReader[];
}

export const bubbleOfWhatsApp = (m: WhatsAppMessage): Bubble => ({
  id: m.id, sender: m.senderName, text: m.text, date: m.date, fromMe: m.fromMe, media: m.media, receipt: m.receipt ?? null, edited: false, deleted: false, replyTo: null, reactions: [], versions: [],
  readAt: null, readBy: [], readers: [],
});

export const bubbleOfInbox = (m: InboxMessage): Bubble => {
  const ext = m as ExtendedInboxMessage;
  return {
    id: m.id, sender: m.sender, text: m.text, date: m.date, fromMe: m.fromMe, media: m.media ?? { kind: "none" }, receipt: m.receipt ?? null,
    edited: !!m.edited, deleted: !!m.deleted, replyTo: m.replyTo ?? null, reactions: m.reactions ?? [], versions: m.versions ?? [],
    readAt: ext.readAt ?? null, readBy: ext.readBy ?? [], readers: ext.readers ?? [],
  };
};

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

/** A call an app noted as a message (`ChatCall`): whether it was video, missed, which way, and how long. */
export interface ChatCall { video: boolean; missed: boolean; outgoing: boolean | null; seconds: number | null }

const CALL_WORDS = new Set(["call", "anruf", "sprachanruf", "videoanruf", "gruppenanruf", "oproep", "spraakoproep", "videooproep",
  "groepsoproep", "gesprek", "videogesprek", "spraakgesprek", "appel", "llamada", "videollamada", "facetime"]);
const MISSED = new Set(["missed", "declined", "gemiste", "gemist", "geweigerde", "geweigerd", "verpasster", "verpasst", "abgelehnter",
  "abgelehnt", "manqué", "refusé", "perdida", "rechazada"]);
const INCOMING = new Set(["incoming", "inkomende", "inkomend", "eingehender", "eingehend", "entrant", "entrante"]);
const OUTGOING = new Set(["outgoing", "uitgaande", "uitgaand", "ausgehender", "ausgehend", "sortant", "saliente"]);
const CALL_MODIFIERS = new Set([...MISSED, ...INCOMING, ...OUTGOING, "voice", "audio", "video", "group", "spraak", "groeps", "vocal",
  "vidéo", "de", "voz", "grupal", "sprachanruf", "videoanruf", "spraakoproep", "videooproep", "videogesprek", "spraakgesprek", "videollamada"]);
const CALL_UNITS = new Set(["min", "mins", "minute", "minutes", "minuut", "minuten", "minuto", "minutos", "sec", "secs", "s", "second",
  "seconds", "seconde", "seconden", "sekunde", "sekunden", "secondes", "segundo", "segundos", "h", "hr", "uur", "std"]);

/** A call line an app wrote as text ("Missed voice call", "Videoanruf · 2:13"), the same words as the Mac's
 *  `ChatFormat.call`; null for any other message. */
export function callOf(text: string): ChatCall | null {
  if (!text || text.length > 60 || text.includes("?") || text.includes("\n")) return null;
  const lower = text.toLowerCase();
  const words = lower.split(/[^\p{L}]+/u).filter((w) => w && !CALL_UNITS.has(w));
  if (!words.length || !words.some((w) => CALL_WORDS.has(w)) || !words.every((w) => CALL_WORDS.has(w) || CALL_MODIFIERS.has(w))) return null;
  let seconds: number | null = null;
  const clock = /\d{1,2}:\d{2}(:\d{2})?/.exec(lower);
  if (clock) seconds = clock[0].split(":").map(Number).reduce((a, b) => a * 60 + b, 0);
  else {
    const minutes = /(\d+)\s*min/.exec(lower);
    if (minutes) seconds = Number(minutes[1]) * 60;
  }
  if (!words.some((w) => CALL_MODIFIERS.has(w)) && seconds === null) return null;
  return {
    video: words.some((w) => w.startsWith("video") || w.startsWith("vidéo")),
    missed: words.some((w) => MISSED.has(w)),
    outgoing: words.some((w) => OUTGOING.has(w)) ? true : words.some((w) => INCOMING.has(w)) ? false : null,
    seconds,
  };
}

/** "0:42", "1:02:05". */
export function callClock(seconds: number): string {
  const total = Math.max(0, Math.round(seconds));
  const [h, m, s] = [Math.floor(total / 3600), Math.floor((total % 3600) / 60), total % 60];
  return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}` : `${m}:${String(s).padStart(2, "0")}`;
}

/** What the chat calls it: "Video call", or "Missed voice call" for one you did not answer. */
export function callTitle(call: ChatCall, mine: boolean): string {
  if (call.missed && !(call.outgoing ?? mine)) return call.video ? tr("Gemiste video-oproep", "Missed video call") : tr("Gemiste spraakoproep", "Missed voice call");
  return call.video ? tr("Video-oproep", "Video call") : tr("Spraakoproep", "Voice call");
}

/** The line under it: who rang, and how long it lasted or that nobody answered ("Incoming · 2:13"). */
export function callDetail(call: ChatCall, mine: boolean): string {
  const way = (call.outgoing ?? mine) ? tr("Uitgaand", "Outgoing") : tr("Inkomend", "Incoming");
  if (call.seconds && call.seconds > 0 && !call.missed) return `${way} · ${callClock(call.seconds)}`;
  if (call.missed && (call.outgoing ?? mine)) return `${way} · ${tr("Niet opgenomen", "No answer")}`;
  return way;
}

/** The first web address in a message's text, for its preview. */
export function firstLink(text: string): string | null {
  for (const word of text.split(/[\s<>"]+/)) {
    if (!/^https?:\/\//.test(word)) continue;
    const link = word.replace(/[.,)!?;:']+$/, "");
    try {
      if (new URL(link).hostname.includes(".")) return link;
    } catch {
      // Not an address after all.
    }
  }
  return null;
}

/** A face's letters (`WAJID.initials`): the first letter of the first two words that start with one, "#" when none. */
export function faceInitials(name: string | null | undefined): string {
  const words = (name ?? "").split(/[ -]+/).filter((w) => /^\p{L}/u.test(w));
  const letters = words.slice(0, 2).map((w) => [...w][0].toUpperCase());
  return letters.length ? letters.join("") : "#";
}

// --- CH-54: Filled receipts, read timestamps, group readers and typing indicators ---

const RECEIPT_RANK: Record<WhatsAppReceipt, number> = {
  failed: 0,
  pending: 1,
  sent: 2,
  delivered: 3,
  read: 4,
};

/** Propagates outgoing receipts and group readers backward to older outgoing messages (`ChatReceipts.filled` and
 *  `ChatReceipts.filledReaders` on the Mac). Never mutates the input array. */
export function fillReceipts(bubbles: Bubble[], isPrivate: boolean): Bubble[] {
  const out = bubbles.map((b) => ({
    ...b,
    readBy: b.readBy ? [...b.readBy] : [],
    readers: b.readers ? b.readers.map((r) => ({ ...r })) : [],
  }));

  let later: WhatsAppReceipt | null = null;
  let laterWentOut = false;
  let theirsLater = false;

  for (let i = out.length - 1; i >= 0; i--) {
    const m = out[i];
    if (!m.fromMe) {
      theirsLater = true;
      continue;
    }
    const raw = m.receipt;
    let receipt: WhatsAppReceipt = raw ?? "sent";
    if (receipt === "pending" && laterWentOut) receipt = "sent";
    if (RECEIPT_RANK[receipt] >= RECEIPT_RANK.sent && later && RECEIPT_RANK[later] > RECEIPT_RANK[receipt]) {
      receipt = later;
    }
    if (receipt === "sent" && isPrivate && theirsLater) {
      receipt = "delivered";
    }
    if (RECEIPT_RANK[receipt] >= RECEIPT_RANK.sent) {
      later = later && RECEIPT_RANK[later] >= RECEIPT_RANK[receipt] ? later : receipt;
    }
    if (raw && RECEIPT_RANK[raw] >= RECEIPT_RANK.sent) {
      laterWentOut = true;
    }
    m.receipt = receipt;
  }

  if (!isPrivate) {
    const laterReaders = new Map<string, { name: string; receipt: WhatsAppReceipt }>();
    const spoken = new Map<string, { name: string; date: string }>();
    for (let i = out.length - 1; i >= 0; i--) {
      const m = out[i];
      if (!m.fromMe) {
        const sender = m.sender.trim();
        if (sender) spoken.set(sender.toLowerCase(), { name: sender, date: m.date });
        continue;
      }
      const readBy = m.readBy!;
      const readers = m.readers!;
      const hasReadBy = (name: string) => readBy.some((n) => n.toLowerCase() === name.toLowerCase());
      const findReader = (lower: string) => readers.find((r) => r.name.toLowerCase() === lower);

      for (const [lower, who] of spoken) {
        const existing = findReader(lower);
        if (existing) {
          if (RECEIPT_RANK[existing.receipt] < RECEIPT_RANK.read) {
            existing.receipt = "read";
            if (!existing.date) existing.date = who.date;
          }
        } else {
          readers.push({ name: who.name, receipt: "read", date: who.date });
        }
        if (!hasReadBy(who.name)) readBy.push(who.name);
      }

      for (const [lower, who] of laterReaders) {
        const existing = findReader(lower);
        if (existing) {
          if (RECEIPT_RANK[who.receipt] > RECEIPT_RANK[existing.receipt]) {
            existing.receipt = who.receipt;
          }
        } else {
          readers.push({ name: who.name, receipt: who.receipt, date: null });
        }
        if (who.receipt === "read" && !hasReadBy(who.name)) readBy.push(who.name);
      }

      for (const name of readBy) {
        if (!findReader(name.toLowerCase())) {
          readers.push({ name, receipt: "read", date: m.readAt ?? null });
        }
      }

      for (const reader of readers) {
        if (RECEIPT_RANK[reader.receipt] >= RECEIPT_RANK.delivered && reader.name.trim()) {
          const lower = reader.name.toLowerCase();
          const prev = laterReaders.get(lower);
          if (!prev || RECEIPT_RANK[reader.receipt] > RECEIPT_RANK[prev.receipt]) {
            laterReaders.set(lower, { name: reader.name, receipt: reader.receipt });
          }
        }
      }
    }
  }

  return out;
}

/** Typing indicator line (`ChatTyping.line` on the Mac): `"{name} is typing…"`, `"{first} and {second} are typing…"`,
 *  `"{first} and {n} others are typing…"`, or `"Typing…"` when no name is given. */
export function typingLine(typing: readonly string[] | null | undefined, isGroup: boolean, fallbackName?: string): string | null {
  if (!typing || !typing.length) return null;
  const seen = new Set<string>();
  const names: string[] = [];
  for (const raw of typing) {
    const clean = raw.trim();
    if (!clean) continue;
    const key = clean.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    names.push(clean);
  }
  if (!names.length) {
    if (!isGroup && fallbackName?.trim()) {
      return tr("{name} is aan het typen…", "{name} is typing…", { name: fallbackName.trim() });
    }
    return tr("Aan het typen…", "Typing…");
  }
  if (names.length === 1) {
    return tr("{name} is aan het typen…", "{name} is typing…", { name: names[0] });
  }
  if (names.length === 2) {
    return tr("{first} en {second} zijn aan het typen…", "{first} and {second} are typing…", { first: names[0], second: names[1] });
  }
  return tr("{first} en {n} anderen zijn aan het typen…", "{first} and {n} others are typing…", { first: names[0], n: names.length - 1 });
}

/** A timestamp as `"14:03"` today, `"Yesterday 14:03"`, or `"12 Oct 14:03"`. */
export function dayAndClock(iso: string | null | undefined, now: Date, locale: string = appLocale()): string {
  const date = dated(iso);
  if (!date) return "";
  const clock = `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
  const today = startOfDay(now).getTime();
  const t = date.getTime();
  if (t >= today && t < today + DAY) return clock;
  if (t >= today - DAY && t < today) return `${tr("Gisteren", "Yesterday")} ${clock}`;
  return `${date.toLocaleDateString(locale, { day: "numeric", month: "short" })} ${clock}`;
}

/** Concise receipt status line for an outgoing message (tooltip, footer, and Message Info). */
export function readReceiptSummary(b: Bubble, isGroup: boolean, now: Date, locale: string = appLocale()): string | null {
  if (!b.fromMe) return null;
  const names = (b.readBy ?? []).map((n) => n.trim()).filter(Boolean);
  if (isGroup && names.length) {
    if (names.length === 1) return tr("Gelezen door {name}", "Read by {name}", { name: names[0] });
    if (names.length === 2) return tr("Gelezen door {first} en {second}", "Read by {first} and {second}", { first: names[0], second: names[1] });
    return tr("Gelezen door {first} en {n} anderen", "Read by {first} and {n} others", { first: names[0], n: names.length - 1 });
  }
  if (b.receipt === "read") {
    const at = dayAndClock(b.readAt, now, locale);
    return at ? tr("Gelezen {time}", "Read {time}", { time: at }) : tr("Gelezen", "Read");
  }
  if (b.receipt === "delivered") return tr("Bezorgd", "Delivered");
  if (b.receipt === "sent") return tr("Verstuurd", "Sent");
  if (b.receipt === "pending") return tr("Versturen…", "Sending…");
  if (b.receipt === "failed") return tr("Niet verstuurd", "Not sent");
  return null;
}

// --- CH-33: People directory aggregated from chats + saved person notes ---

export interface PersonNoteData {
  note: string;
  birthday: string | null;
}

export interface ChatPerson {
  /** Stable deduplication key (folded name or normalized handle). */
  id: string;
  name: string;
  handle: string | null;
  /** The person's private chats across apps, newest first. */
  chats: ChatEntry[];
  /** Unique app ids where you chat with this person, most recent first. */
  apps: string[];
  last: Date | null;
  unread: number;
  primaryChat: ChatEntry;
}

/** Name folding matching Mac `ChatPeople` / Rust `fold`: diacritics & invisible marks stripped, lowercased, collapsed. */
export function foldPersonName(name: string): string {
  const visible = name.replace(/[\u200B-\u200F\u202A-\u202E\u2060-\u2069\uFEFF]/g, "");
  return visible
    .normalize("NFKD")
    .replace(/\p{M}+/gu, "")
    .toLowerCase()
    .trim()
    .replace(/\s+/g, " ");
}

function normalizedHandle(handle: string | null | undefined): string | null {
  if (!handle) return null;
  const trimmed = handle.trim().toLowerCase();
  if (!trimmed) return null;
  if (trimmed.includes("@")) return trimmed;
  const digits = trimmed.replace(/\D+/g, "");
  return digits.length >= 7 ? `tel:${digits}` : null;
}

const looksLikePhone = (name: string) => /^[\d\s+().-]+$/.test(name.trim()) && name.replace(/\D+/g, "").length >= 7;

/** Stable grouping key for a person across apps (`ChatPeople`). */
export function personKey(name: string, handle?: string | null): string {
  const folded = foldPersonName(name);
  const h = normalizedHandle(handle);
  if ((!folded || looksLikePhone(name)) && h) return h;
  return folded || h || "";
}

/** Aggregates private chats across apps into deduplicated people, newest interaction first (`ChatPeople`). */
export function aggregatePeople(entries: ChatEntry[]): ChatPerson[] {
  const privateChats = entries
    .filter((e) => !e.isGroup && e.listKind === "chats" && e.name.trim().length > 0)
    .sort((a, b) => (b.last?.getTime() ?? 0) - (a.last?.getTime() ?? 0));

  const groups: { key: string; handleKey: string | null; chats: ChatEntry[] }[] = [];
  const byKey = new Map<string, number>();
  const byHandle = new Map<string, number>();

  for (const chat of privateChats) {
    const k = personKey(chat.name, chat.handle);
    if (!k) continue;
    const h = normalizedHandle(chat.handle);
    let idx = byKey.get(k);
    if (idx === undefined && h) idx = byHandle.get(h);
    if (idx === undefined) {
      idx = groups.length;
      groups.push({ key: k, handleKey: h, chats: [chat] });
      byKey.set(k, idx);
      if (h) byHandle.set(h, idx);
    } else {
      const g = groups[idx];
      g.chats.push(chat);
      if (!byKey.has(k)) byKey.set(k, idx);
      if (h && !byHandle.has(h)) {
        g.handleKey ??= h;
        byHandle.set(h, idx);
      }
    }
  }

  return groups
    .map((g) => {
      const chats = g.chats.sort((a, b) => (b.last?.getTime() ?? 0) - (a.last?.getTime() ?? 0));
      const named = chats.find((c) => c.name.trim() && !looksLikePhone(c.name)) ?? chats[0];
      const handle = chats.find((c) => c.handle)?.handle ?? null;
      const apps = [...new Set(chats.map((c) => c.app))];
      const unread = chats.reduce((sum, c) => sum + c.unread, 0);
      return {
        id: g.key,
        name: named.name.trim(),
        handle,
        chats,
        apps,
        last: chats[0]?.last ?? null,
        unread,
        primaryChat: chats[0],
      };
    })
    .sort((a, b) => (b.last?.getTime() ?? 0) - (a.last?.getTime() ?? 0) || a.name.localeCompare(b.name));
}

/** Whether a `"MM-DD"` birthday matches `now`. */
export function isBirthdayToday(mmdd: string | null | undefined, now: Date): boolean {
  if (!mmdd) return false;
  const m = /^(\d{2})-(\d{2})$/.exec(mmdd.trim());
  if (!m) return false;
  return Number(m[1]) === now.getMonth() + 1 && Number(m[2]) === now.getDate();
}

/** Formats `"MM-DD"` (e.g. `"04-12"`) into a localized day and month (`"12 April"` / `"12 april"`). */
export function formatBirthday(mmdd: string | null | undefined, locale: string = appLocale()): string {
  if (!mmdd) return "";
  const m = /^(\d{2})-(\d{2})$/.exec(mmdd.trim());
  if (!m) return "";
  const month = Number(m[1]);
  const day = Number(m[2]);
  if (month < 1 || month > 12 || day < 1 || day > 31) return "";
  // 2024 is a leap year so 02-29 formats cleanly.
  const date = new Date(2024, month - 1, day);
  if (date.getMonth() !== month - 1 || date.getDate() !== day) return "";
  return date.toLocaleDateString(locale, { day: "numeric", month: "long" });
}

/** Filters `people` by name, handle, app name, chat preview, or saved person note (`ChatPeopleView`). */
export function searchPeople(people: ChatPerson[], query: string, notes: Record<string, PersonNoteData>): ChatPerson[] {
  const needle = foldPersonName(query);
  if (!needle) return people;
  return people.filter((p) => {
    const noteText = p.chats.map((c) => notes[c.key]?.note ?? "").join(" ");
    const haystack = [
      p.name,
      p.handle ?? "",
      ...p.apps.map((a) => appName(a)),
      ...p.chats.map((c) => c.preview),
      noteText,
    ].join("\n");
    return foldPersonName(haystack).includes(needle);
  });
}
