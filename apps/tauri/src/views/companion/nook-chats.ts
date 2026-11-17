// What the phone can do to one of Nook's conversations, as the Mac's Nook tab offers it (`CompanionNookChats.swift`,
// `nookChats`): one menu for a conversation, used by the list (a long press) and by the open conversation (its "…"),
// and the one way to send an action (`chatAct`).
import { companion, nookMarkdown, type CallResult, type ChatDigest, type NookChatAction } from "../../lib/companion";
import { tr } from "../../lib/i18n.svelte";
import type { MenuItem } from "./ui/Menu.svelte";
import type { ChatConfirm } from "./chat-actions";

/** Sends one action; the answer has the list as it is after it. */
export function nookAct(conversation: string, action: NookChatAction): Promise<CallResult> {
  return companion.call({ op: "chatAct", conversation, nookAction: action });
}

/** Copies the conversation as Markdown, reading its messages first. */
export async function copyNookChat(chat: ChatDigest): Promise<void> {
  const r = await companion.call({ op: "chat", conversation: chat.id });
  await navigator.clipboard?.writeText(nookMarkdown(chat.title, r.response?.messages ?? []));
}

/** The conversation's menu: rename, pin, read state, copy, retry (in the conversation), archive and delete. A
 * conversation Nook still writes in is not archived, deleted or asked again, as on the Mac. */
export function nookMenu(
  chat: ChatDigest,
  run: (action: NookChatAction) => void,
  confirm: (c: ChatConfirm) => void,
  rename: () => void,
  retry = false,
): MenuItem[][] {
  const first: MenuItem[] = [{ label: tr("Hernoem", "Rename"), icon: "pencil", onselect: rename }];
  if (!chat.archived) {
    first.push(chat.pinned
      ? { label: tr("Maak los", "Unpin"), icon: "pin-off", onselect: () => run({ kind: "pin", value: false }) }
      : { label: tr("Zet vast", "Pin"), icon: "pin", onselect: () => run({ kind: "pin", value: true }) });
  }
  first.push(chat.unread
    ? { label: tr("Markeer als gelezen", "Mark as read"), icon: "mail-open", onselect: () => run({ kind: "markUnread", value: false }) }
    : { label: tr("Markeer als ongelezen", "Mark as unread"), icon: "mail", onselect: () => run({ kind: "markUnread", value: true }) });
  first.push({ label: tr("Kopieer gesprek", "Copy conversation"), icon: "copy", onselect: () => void copyNookChat(chat) });
  if (retry) first.push({ label: tr("Probeer laatste antwoord opnieuw", "Retry last answer"), icon: "rotate-ccw", disabled: chat.busy, onselect: () => run({ kind: "retry" }) });
  const last: MenuItem[] = [
    chat.archived
      ? { label: tr("Haal uit archief", "Unarchive"), icon: "archive", disabled: chat.busy, onselect: () => run({ kind: "archive", value: false }) }
      : { label: tr("Archiveer", "Archive"), icon: "archive", disabled: chat.busy, onselect: () => run({ kind: "archive", value: true }) },
    {
      label: tr("Verwijderen", "Delete"), icon: "trash-2", destructive: true, disabled: chat.busy,
      onselect: () => confirm({
        title: tr("“{title}” verwijderen?", "Delete “{title}”?", { title: chat.title }),
        message: tr("Het gesprek verdwijnt ook uit Nook op je Mac. Dit kan niet ongedaan worden.", "The conversation is gone from Nook on your Mac too. This cannot be undone."),
        button: tr("Verwijderen", "Delete"),
        run: () => run({ kind: "delete" }),
      }),
    },
  ];
  return [first, last];
}
