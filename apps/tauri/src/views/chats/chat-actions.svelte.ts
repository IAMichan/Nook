// What can be done with a chat, the same in its row's right-click menu and the open chat's "…" menu, for every chat app
// (`ChatsTab.rowMenu`, `ChatsDetail.moreMenu`, `ChatAbilities` CH-58): read and unread by where it stands, pinning on
// top in Nook or in the app, muting/archiving where its app allows, and removing it from Nook after a yes. Pins are
// kept on this computer (`ChatPins`) and synced to the app when `abilities.pin` is true.
import { invoke } from "@tauri-apps/api/core";
import type { MenuItem } from "../../components/ui/Menu.svelte";
import { api } from "../../lib/api";
import { ask } from "../../lib/confirm.svelte";
import { chatsApi, connectorsApi } from "../../lib/connectors";
import { appName, entryAbilities, type ChatEntry } from "../../lib/chats-list";
import { tr } from "../../lib/i18n.svelte";
import { toast } from "../../lib/toast.svelte";
import { whatsapp } from "../../lib/whatsapp.svelte";

const PINS = "chats.pins";

class ChatPins {
  keys = $state<string[]>(load());
  has(key: string) {
    return this.keys.includes(key);
  }
  set(key: string, pinned: boolean) {
    const exists = this.has(key);
    if (pinned === exists) return;
    this.keys = pinned ? [key, ...this.keys] : this.keys.filter((k) => k !== key);
    try {
      localStorage.setItem(PINS, JSON.stringify(this.keys));
    } catch {
      // Pinned until the window closes.
    }
  }
  toggle(key: string) {
    this.set(key, !this.has(key));
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

function isCommandUnavailable(err: unknown): boolean {
  const msg = String(err ?? "").toLowerCase();
  return msg.includes("not found") || msg.includes("unknown command") || msg.includes("not allowed");
}

/** Invokes a newly added Wave-5 Tauri command, falling back cleanly if `lib.rs` has not registered it yet. */
export async function invokeOrFallback<T>(
  cmd: string,
  args: Record<string, unknown>,
  fallback: () => Promise<T>,
): Promise<T> {
  try {
    return await invoke<T>(cmd, args);
  } catch (err) {
    if (isCommandUnavailable(err)) return await fallback();
    throw err;
  }
}

async function run(step: () => Promise<unknown>) {
  try {
    await step();
    whatsapp.version++;
  } catch (e) {
    toast.error(tr("Dat lukte niet", "That did not work"), e);
  }
}

export const isChatPinned = (e: ChatEntry) => pins.has(e.key) || !!e.pinned || !!e.abilities?.pinned;
export const isChatMuted = (e: ChatEntry) => !!e.mutedInApp || !!e.abilities?.muted;
export const isChatArchived = (e: ChatEntry) => !!e.archived || !!e.abilities?.archived;

export const markReadInNook = (e: ChatEntry) => run(() => chatsApi.markRead(e.key, false));
export const markReadInApp = (e: ChatEntry) => run(() => chatsApi.markRead(e.key, true));
export const markUnread = (e: ChatEntry) =>
  run(() =>
    invokeOrFallback("chat_mark_unread", { key: e.key }, () => chatsApi.markUnread(e.key)),
  );

export function togglePin(e: ChatEntry) {
  const abilities = entryAbilities(e);
  const next = !isChatPinned(e);
  pins.set(e.key, next);
  return run(() =>
    invokeOrFallback("chat_set_pinned", { key: e.key, pinned: next }, () =>
      abilities.pin ? chatsApi.inApp(e.key, { pinned: next }) : Promise.resolve(),
    ),
  );
}

export function toggleMute(e: ChatEntry) {
  const abilities = entryAbilities(e);
  const next = !isChatMuted(e);
  return run(() =>
    invokeOrFallback("chat_set_muted", { key: e.key, muted: next }, async () => {
      if (e.app === "whatsapp") {
        await connectorsApi.whatsappSetMode(e.id, next ? "muted" : "automatic");
      } else if (abilities.mute) {
        await chatsApi.inApp(e.key, { muted: next });
      }
    }),
  );
}

export function toggleArchive(e: ChatEntry, after?: () => void) {
  const abilities = entryAbilities(e);
  const next = !isChatArchived(e);
  if (next) after?.();
  return run(() =>
    invokeOrFallback("chat_set_archived", { key: e.key, archived: next }, async () => {
      if (abilities.archive) {
        await chatsApi.inApp(e.key, { archived: next });
      } else if (e.app === "whatsapp" && next) {
        await connectorsApi.whatsappIgnore(e.id);
      }
    }),
  );
}

/** Removes the chat from Nook after a yes; its app keeps it unless `abilities.deleteChat` says otherwise. */
export async function remove(e: ChatEntry, after?: () => void) {
  const abilities = entryAbilities(e);
  const yes = await ask({
    question: tr("“{name}” verwijderen?", "Delete “{name}”?", { name: e.name }),
    detail: abilities.deleteChat
      ? tr("Het gesprek en de berichten worden in Nook en {app} verwijderd.", "The conversation and its messages are deleted in Nook and {app}.", { app: appName(e.app) })
      : tr("Het gesprek en de berichten worden uit Nook verwijderd. In {app} blijft het staan.", "The conversation and its messages are removed from Nook. It stays in {app}.", { app: appName(e.app) }),
    confirmTitle: tr("Verwijder chat", "Remove chat"),
  });
  if (!yes) return;
  after?.();
  await run(() =>
    invokeOrFallback("chat_delete", { key: e.key }, () => chatsApi.remove(e.key)),
  );
}

export const deleteChat = remove;

/** Marks all unread chats in `entries` read in Nook (used from sidebar app menu). */
export async function markAllReadInNook(entries: ChatEntry[]) {
  const unread = entries.filter((e) => e.read === "unread");
  if (!unread.length) return;
  await run(async () => {
    for (const e of unread) {
      await chatsApi.markRead(e.key, false);
    }
  });
}

/** The menu's sections for a chat, respecting `ChatAbilities`. `close` runs when the step takes the open chat away. */
export function chatMenu(e: ChatEntry, close?: () => void): MenuItem[][] {
  const app = appName(e.app);
  const abilities = entryAbilities(e);
  const pinned = isChatPinned(e);
  const muted = isChatMuted(e);
  const archived = isChatArchived(e);

  const read: MenuItem[] = [
    ...(e.read === "unread" ? [{ label: tr("Gelezen in Nook", "Read in Nook"), icon: "check", onselect: () => markReadInNook(e) }] : []),
    ...(e.read !== "read" && abilities.markRead
      ? [{ label: tr("Markeer gelezen in {app}", "Mark as read in {app}", { app }), icon: "check-check", onselect: () => markReadInApp(e) }]
      : []),
    ...(e.read !== "unread"
      ? [{ label: tr("Markeer als ongelezen", "Mark as unread"), icon: "circle-dot", onselect: () => markUnread(e) }]
      : []),
  ];

  const own: MenuItem[] = [
    {
      label: abilities.pin
        ? (pinned ? tr("Losmaken in {app}", "Unpin in {app}", { app }) : tr("Vastzetten in {app}", "Pin in {app}", { app }))
        : (pinned ? tr("Losmaken", "Unpin") : tr("Bovenaan vastzetten", "Pin to top")),
      icon: pinned ? "pin-off" : "pin",
      onselect: () => togglePin(e),
    },
  ];

  // Respect `ChatAbilities`: helper apps with `mute`/`archive` act in the app itself; WhatsApp handles mute/archive/hide
  // in Nook cleanly without promising unsupported gateway mutations.
  const inApp: MenuItem[] = [];
  if (abilities.mute) {
    inApp.push({
      label: muted ? tr("Niet meer dempen in {app}", "Unmute in {app}", { app }) : tr("Dempen in {app}", "Mute in {app}", { app }),
      icon: muted ? "bell" : "bell-off",
      onselect: () => toggleMute(e),
    });
  } else if (e.app === "whatsapp") {
    inApp.push({
      label: muted ? tr("Niet meer dempen", "Unmute") : tr("Dempen", "Mute"),
      icon: muted ? "bell" : "bell-off",
      onselect: () => toggleMute(e),
    });
  }

  if (abilities.archive) {
    inApp.push({
      label: archived ? tr("Uit archief halen in {app}", "Unarchive in {app}", { app }) : tr("Archiveren in {app}", "Archive in {app}", { app }),
      icon: "archive",
      onselect: () => toggleArchive(e, close),
    });
  } else if (e.app === "whatsapp") {
    inApp.push({
      label: archived ? tr("Uit archief halen", "Unarchive") : tr("Archiveren", "Archive"),
      icon: "archive",
      onselect: () => toggleArchive(e, close),
    });
    inApp.push({
      label: tr("Niet meer tonen", "Stop showing"),
      icon: "eye-off",
      onselect: () => {
        close?.();
        run(async () => { await connectorsApi.whatsappIgnore(e.id); });
      },
    });
  }

  const gone: MenuItem[] = [
    { label: tr("Verwijder chat", "Remove chat"), icon: "trash-2", destructive: true, onselect: () => remove(e, close) },
  ];
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

