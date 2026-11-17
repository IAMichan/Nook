// What the phone can do to a chat and its messages in the Chats tab, as the Mac's Chats tab offers it
// (`CompanionChats.swift`, `chatActions`): one menu for a chat, used by the list and by the open chat, built from what
// the chat's app takes (`InboxChatDigest.abilities`), and the one way to send an action (`inboxAct`).
import { abilities, companion, readState, type CallResult, type InboxAction, type InboxChatDigest, type InboxLine } from "../../lib/companion";
import { tr } from "../../lib/i18n.svelte";
import type { MenuItem } from "./ui/Menu.svelte";

/** A destructive step asked about first, as the `Dialog` shows it. */
export interface ChatConfirm { title: string; message: string; button: string; run: () => void }

/** Sends one action in a chat; the answer has the chat's messages and the list as they are after it. */
export function act(chat: string, action: InboxAction): Promise<CallResult> {
  return companion.call({ op: "inboxAct", item: chat, chatAction: action });
}

/** The menu of a chat: its read state, pinning and muting, archiving, and taking it away. Each row only where the
 * chat's app takes it; removing and deleting are asked about first. `info` opens the chat's info where it has one. */
export function chatMenu(
  chat: InboxChatDigest,
  run: (action: InboxAction) => void,
  confirm: (c: ChatConfirm) => void,
  info?: () => void,
): MenuItem[][] {
  const can = abilities(chat);
  const app = chat.appName;
  const state = readState(chat);
  const read: MenuItem[] = [];
  if (state === "unread") read.push({ label: tr("Gelezen in Nook", "Mark as read in Nook"), icon: "mail-open", onselect: () => run({ kind: "markReadInNook" }) });
  if (state !== "read" && can.has("markReadInApp")) read.push({ label: tr("Markeer gelezen in {app}", "Mark as read in {app}", { app }), icon: "mail-open", onselect: () => run({ kind: "markReadInApp" }) });
  if (state !== "unread") read.push({ label: tr("Markeer als ongelezen", "Mark as unread"), icon: "mail", onselect: () => run({ kind: "markUnread" }) });
  const keep: MenuItem[] = [
    chat.pinned
      ? { label: tr("Losmaken in Nook", "Unpin in Nook"), icon: "pin-off", onselect: () => run({ kind: "pin", value: false }) }
      : { label: tr("Vastzetten in Nook", "Pin in Nook"), icon: "pin", onselect: () => run({ kind: "pin", value: true }) },
  ];
  if (can.has("pinInApp")) {
    keep.push(chat.pinnedInApp
      ? { label: tr("Losmaken in {app}", "Unpin in {app}", { app }), icon: "pin-off", onselect: () => run({ kind: "pinInApp", value: false }) }
      : { label: tr("Vastzetten in {app}", "Pin in {app}", { app }), icon: "pin", onselect: () => run({ kind: "pinInApp", value: true }) });
  }
  if (can.has("muteInApp")) {
    keep.push(chat.mutedInApp
      ? { label: tr("Dempen opheffen in {app}", "Unmute in {app}", { app }), icon: "bell", onselect: () => run({ kind: "muteInApp", value: false }) }
      : { label: tr("Dempen in {app}", "Mute in {app}", { app }), icon: "bell-off", onselect: () => run({ kind: "muteInApp", value: true }) });
  }
  if (can.has("archive")) keep.push({ label: tr("Archiveer in {app}", "Archive in {app}", { app }), icon: "archive", onselect: () => run({ kind: "archive" }) });
  if (info && chat.hasInfo) keep.push({ label: tr("Chatinfo", "Chat info"), icon: "info", onselect: info });
  const away: MenuItem[] = [{
    label: tr("Verwijder uit Nook", "Remove from Nook"), icon: "x", destructive: true,
    onselect: () => confirm({
      title: tr("{name} uit Nook verwijderen?", "Remove {name} from Nook?", { name: chat.name }),
      message: tr("Hij verdwijnt uit Nooks Chats tot er een nieuw bericht binnenkomt. In de app zelf verandert niets.", "It leaves Nook's Chats until a new message comes in. Nothing changes in the app itself."),
      button: tr("Verwijder", "Remove"),
      run: () => run({ kind: "remove" }),
    }),
  }];
  if (can.has("deleteChat")) {
    away.push({
      label: tr("Verwijder in {app}", "Delete in {app}", { app }), icon: "trash-2", destructive: true,
      onselect: () => confirm({
        title: tr("{name} verwijderen in {app}?", "Delete {name} in {app}?", { name: chat.name, app }),
        message: tr("De chat wordt voor jou verwijderd in {app}; een groep verlaat je ook. Dit kan niet ongedaan worden gemaakt.", "The chat is deleted in {app} for you; a group you also leave. This cannot be undone.", { app }),
        button: tr("Verwijder", "Delete"),
        run: () => run({ kind: "deleteChat" }),
      }),
    });
  }
  return [read, keep, away];
}

/** What a message's menu offers besides its quick reactions. */
export interface MessageMenuActions {
  reply?: () => void;
  edit?: () => void;
  forward?: () => void;
  info?: () => void;
}

/** The rows of a message's menu: reply, copy, edit, forward, message info and deleting it (asked about first). A
 * message the app does not have back yet (`local`) can only be copied. */
export function messageMenu(
  chat: InboxChatDigest,
  line: InboxLine,
  run: (action: InboxAction) => void,
  confirm: (c: ChatConfirm) => void,
  open: MessageMenuActions,
): MenuItem[][] {
  const can = abilities(chat);
  const copy: MenuItem = { label: tr("Kopieer", "Copy"), icon: "copy", onselect: () => navigator.clipboard?.writeText(line.text).catch(() => {}) };
  if (line.local) return [[copy]];
  const main: MenuItem[] = [];
  if (open.reply && chat.canSend && !line.deleted) main.push({ label: tr("Beantwoord", "Reply"), icon: "reply", onselect: open.reply });
  if (line.text) main.push(copy);
  if (open.edit && line.fromMe && can.has("edit") && !line.deleted && !line.poll && line.text) main.push({ label: tr("Wijzig", "Edit"), icon: "pencil", onselect: open.edit });
  if (open.forward && !line.deleted && !line.notice) main.push({ label: tr("Doorsturen", "Forward"), icon: "forward", onselect: open.forward });
  if (open.info && line.fromMe && line.readers?.length) main.push({ label: tr("Berichtinfo", "Message info"), icon: "info", onselect: open.info });
  const away: MenuItem[] = [{
    label: tr("Verwijder voor mij", "Delete for me"), icon: "trash-2", destructive: true,
    onselect: () => confirm({
      title: tr("Dit bericht verwijderen?", "Delete this message?"),
      message: can.has("deleteForMe")
        ? tr("Weg uit Nook en uit {app}, voor jou.", "Gone from Nook and from {app}, for you.", { app: chat.appName })
        : tr("Weg uit Nook. In {app} blijft het staan.", "Gone from Nook. It stays in {app}.", { app: chat.appName }),
      button: tr("Verwijder", "Delete"),
      run: () => run({ kind: "deleteForMe", message: line.id }),
    }),
  }];
  if (line.fromMe && can.has("delete") && !line.deleted) {
    away.push({
      label: tr("Verwijder voor iedereen", "Delete for everyone"), icon: "trash-2", destructive: true,
      onselect: () => confirm({
        title: tr("Dit bericht verwijderen?", "Delete this message?"),
        message: tr("Iedereen in de chat ziet dat het verwijderd is.", "Everyone in the chat sees that it was deleted."),
        button: tr("Verwijder", "Delete"),
        run: () => run({ kind: "delete", message: line.id }),
      }),
    });
  }
  return [main, away];
}
