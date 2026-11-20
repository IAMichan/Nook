// What can be done with a chat, the same in its row's right-click menu and the open chat's "…" menu, for every chat app
// (`ChatsTab.rowMenu`, `ChatsDetail.moreMenu`): read and unread by where it stands, pinning it on top in Nook, what
// WhatsApp lets Nook do with it, and removing it from Nook after a yes. Pins are kept on this computer (`ChatPins`).
import type { MenuItem } from "../../components/ui/Menu.svelte";
import { api } from "../../lib/api";
import { ask } from "../../lib/confirm.svelte";
import { chatsApi, connectorsApi } from "../../lib/connectors";
import { appName, type ChatEntry } from "../../lib/chats-list";
import { tr } from "../../lib/i18n.svelte";
import { toast } from "../../lib/toast.svelte";
import { whatsapp } from "../../lib/whatsapp.svelte";

const PINS = "chats.pins";

class ChatPins {
  keys = $state<string[]>(load());
  has(key: string) {
    return this.keys.includes(key);
  }
  toggle(key: string) {
    this.keys = this.has(key) ? this.keys.filter((k) => k !== key) : [key, ...this.keys];
    try {
      localStorage.setItem(PINS, JSON.stringify(this.keys));
    } catch {
      // Pinned until the window closes.
    }
  }
}

function load(): string[] {
  try {
    const v = JSON.parse(localStorage.getItem(PINS) ?? "[]");
    return Array.isArray(v) ? v.filter((x) => typeof x === "string") : [];
  } catch {
    return [];
  }
}

export const pins = new ChatPins();

async function run(step: () => Promise<unknown>) {
  try {
    await step();
    whatsapp.version++;
  } catch (e) {
    toast.error(tr("Dat lukte niet", "That did not work"), e);
  }
}

export const markReadInNook = (e: ChatEntry) => run(() => chatsApi.markRead(e.key, false));
export const markReadInApp = (e: ChatEntry) => run(() => chatsApi.markRead(e.key, true));
export const markUnread = (e: ChatEntry) => run(() => chatsApi.markUnread(e.key));

/** Removes the chat from Nook after a yes; its app keeps it. */
export async function remove(e: ChatEntry, after?: () => void) {
  const yes = await ask({
    question: tr("“{name}” verwijderen?", "Delete “{name}”?", { name: e.name }),
    detail: tr("Het gesprek en de berichten worden uit Nook verwijderd. In {app} blijft het staan.", "The conversation and its messages are removed from Nook. It stays in {app}.", { app: appName(e.app) }),
    confirmTitle: tr("Verwijder chat", "Remove chat"),
  });
  if (!yes) return;
  after?.();
  await run(() => chatsApi.remove(e.key));
}

/** The menu's sections for a chat. `close` runs when the step takes the open chat away. */
export function chatMenu(e: ChatEntry, close?: () => void): MenuItem[][] {
  const app = appName(e.app);
  const read: MenuItem[] = [
    ...(e.read === "unread" ? [{ label: tr("Gelezen in Nook", "Read in Nook"), icon: "check", onselect: () => markReadInNook(e) }] : []),
    ...(e.read !== "read" ? [{ label: tr("Markeer gelezen in {app}", "Mark as read in {app}", { app }), icon: "check-check", onselect: () => markReadInApp(e) }] : []),
    ...(e.read !== "unread" ? [{ label: tr("Markeer als ongelezen", "Mark as unread"), icon: "circle-dot", onselect: () => markUnread(e) }] : []),
  ];
  const pinned = pins.has(e.key);
  const own: MenuItem[] = [{ label: pinned ? tr("Losmaken", "Unpin") : tr("Bovenaan vastzetten", "Pin to top"), icon: "pin", onselect: () => pins.toggle(e.key) }];
  // What its app lets Nook do with the chat (`ChatAppActions`): the helper's apps mute and archive in the app itself;
  // WhatsApp's gateway cannot, so there Nook keeps it quiet or leaves it out of Nook.
  const inApp: MenuItem[] = e.app !== "whatsapp"
    ? e.sends
      ? [
          { label: e.mutedInApp ? tr("Niet meer dempen in {app}", "Unmute in {app}", { app }) : tr("Dempen in {app}", "Mute in {app}", { app }), icon: "bell-off", onselect: () => run(() => chatsApi.inApp(e.key, { muted: !e.mutedInApp })) },
          { label: tr("Archiveren in {app}", "Archive in {app}", { app }), icon: "archive", onselect: () => { close?.(); run(() => chatsApi.inApp(e.key, { archived: true })); } },
        ]
      : []
    : [
        { label: tr("Dempen", "Mute"), icon: "bell-off", onselect: () => run(async () => { await connectorsApi.whatsappMute(e.id); }) },
        { label: tr("Niet meer tonen", "Stop showing"), icon: "eye-off", onselect: () => { close?.(); run(async () => { await connectorsApi.whatsappIgnore(e.id); }); } },
      ];
  const gone: MenuItem[] = [{ label: tr("Verwijder chat", "Remove chat"), icon: "trash-2", destructive: true, onselect: () => remove(e, close) }];
  return [read, own, inApp, gone].filter((s) => s.length);
}

/** Settings › Chat apps, where a chat app is linked. */
export function openChatSettings() {
  try {
    localStorage.setItem("settings.section", "chats");
  } catch {
    // The window opens on its last section instead.
  }
  api.showMain("settings");
}
