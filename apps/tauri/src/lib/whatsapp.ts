// What the WhatsApp card in the bar shows, as plain helpers: the words for files and ticks, the time of a bubble, and
// the per-chat list in the settings. Everything here comes from other people's messages, so it is only ever shown as
// text (never as HTML) by the views.
import { tr } from "./i18n.svelte";
import type { WhatsAppChatKind, WhatsAppChatMode, WhatsAppMedia, WhatsAppMessage, WhatsAppReceipt, WhatsAppSettingsChat } from "./connectors";

/** What a bubble calls a file that can be opened: a document by its name, anything else by its kind. */
export function fileLabel(media: WhatsAppMedia): string | null {
  switch (media.kind) {
    case "document":
      return media.name?.trim() || tr("Document", "Document");
    case "image":
      return tr("Foto", "Photo");
    case "video":
      return tr("Video", "Video");
    case "audio":
    case "voice":
      return tr("Spraakbericht", "Voice message");
    default:
      return null;
  }
}

/** The text of a bubble: a sticker, place or contact says what it is; a file shows as its own row instead. */
export function bubbleText(message: WhatsAppMessage): string {
  const label: Partial<Record<WhatsAppMedia["kind"], string>> = {
    sticker: tr("Sticker", "Sticker"),
    location: tr("Locatie", "Location"),
    contact: tr("Contact", "Contact"),
    other: tr("Bijlage", "Attachment"),
  };
  return [label[message.media?.kind ?? "none"], message.text].filter((part) => part && part.trim()).join(" ");
}

/** WhatsApp's ticks for your own message: a clock while sending, one grey tick on the server, two when delivered,
 *  two blue ones once read, and a red mark when sending failed. */
export function ticks(receipt: WhatsAppReceipt | null | undefined): { symbol: string; title: string; tone: string } | null {
  switch (receipt) {
    case "pending":
      return { symbol: "🕓", title: tr("Wordt verzonden", "Sending"), tone: "pending" };
    case "sent":
      return { symbol: "✓", title: tr("Verzonden", "Sent"), tone: "sent" };
    case "delivered":
      return { symbol: "✓✓", title: tr("Afgeleverd", "Delivered"), tone: "delivered" };
    case "read":
      return { symbol: "✓✓", title: tr("Gelezen", "Read"), tone: "read" };
    case "failed":
      return { symbol: "!", title: tr("Niet verzonden", "Not sent"), tone: "failed" };
    default:
      return null;
  }
}

/** "14:02" in the local time zone. */
export function time(date: string): string {
  const d = new Date(date);
  if (Number.isNaN(d.getTime())) return "";
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}

/** The card's context line: "WhatsApp · 3 new" from two unread messages on. */
export function context(unread: number): string {
  return unread > 1 ? tr("WhatsApp · {n} nieuw", "WhatsApp · {n} new", { n: unread }) : "WhatsApp";
}

/// Getters, so each read is in the current interface language.
export const kindLabel: Record<WhatsAppChatKind, string> = {
  get person() { return tr("Persoon", "Person"); },
  get group() { return tr("Groep", "Group"); },
  get status() { return tr("Statusupdates", "Status updates"); },
  get channel() { return tr("Kanaal", "Channel"); },
};

export const modeLabel: Record<WhatsAppChatMode, string> = {
  get automatic() { return tr("Automatisch", "Automatic"); },
  get loud() { return tr("Altijd", "Always"); },
  get muted() { return tr("Nooit", "Never"); },
};

/** The chats under "Per chat" that fit the search (by name, ignoring case), hidden ones apart. */
export function settingsChats(all: WhatsAppSettingsChat[], query: string): { shown: WhatsAppSettingsChat[]; hidden: WhatsAppSettingsChat[] } {
  const needle = query.trim().toLowerCase();
  return {
    shown: all.filter((c) => !c.hidden && (!needle || c.name.toLowerCase().includes(needle))),
    hidden: all.filter((c) => c.hidden),
  };
}

/** Two letters for a chat's avatar. */
export function initials(name: string): string {
  const words = name.replace(/[^\p{L}\p{N} ]/gu, " ").split(/\s+/).filter(Boolean);
  const letters = words.length > 1 ? words[0][0] + words[words.length - 1][0] : (words[0] ?? "?").slice(0, 2);
  return letters.toUpperCase();
}
