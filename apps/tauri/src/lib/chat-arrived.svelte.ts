// A new message in any chat app but WhatsApp (which has its own card) for the bar (the Mac's notch chat card,
// `ChatNoticeCard`): Rust sends `chat-arrived` with the chat's key when Settings › Notifications shows that app as a
// card or a strip. The closed bar shows a chip ("Message from Lisa"); opening the bar shows the chat's last messages
// with a field to answer. A new message never opens the bar by itself, and a draft you are typing keeps its card.
import { emit, listen } from "@tauri-apps/api/event";
import { chatsApi, type ChatThread } from "./connectors";

export interface ChatArrived { key: string; app: string; name: string; preview: string; unread: number; style: "card" | "strip" }

class ArrivedChat {
  pending = $state<ChatArrived | null>(null);
  thread = $state<ChatThread | null>(null);
  draft = $state("");
  sending = $state(false);
  error = $state<string | null>(null);
  private started = false;

  start() {
    if (this.started) return;
    this.started = true;
    listen<ChatArrived>("chat-arrived", (e) => {
      if (this.thread && this.thread.key !== e.payload.key && this.draft.trim()) return;
      if (this.thread?.key === e.payload.key) this.reload();
      else this.pending = e.payload;
    }).catch(() => {});
  }

  /// The card for the waiting chat (when the bar opens).
  async show() {
    const key = this.pending?.key;
    if (!key) return;
    this.pending = null;
    this.draft = "";
    this.error = null;
    this.thread = await chatsApi.thread(key).catch(() => null);
  }

  async reload() {
    if (this.thread) this.thread = (await chatsApi.thread(this.thread.key).catch(() => null)) ?? this.thread;
  }

  async send() {
    const thread = this.thread;
    const text = this.draft.trim();
    if (!thread || !text || this.sending) return;
    this.sending = true;
    this.error = null;
    try {
      await chatsApi.send(thread.key, text, null);
      await chatsApi.markRead(thread.key, false).catch(() => {});
      this.dismiss();
    } catch (e) {
      this.error = String(e);
    } finally {
      this.sending = false;
    }
  }

  async markRead() {
    if (this.thread) await chatsApi.markRead(this.thread.key, false).catch(() => {});
    this.dismiss();
  }

  dismiss() {
    this.pending = null;
    this.thread = null;
    this.draft = "";
    this.error = null;
  }
}

export const arrivedChat = new ArrivedChat();

/// Opens one chat in the Chats tab of this window: one already on screen switches at once (`nook-open-chat`), one that
/// mounts next opens it from the remembered key. `everywhere` also tells the other windows (the main window's Chats).
export function showChat(key: string, everywhere = false) {
  try { localStorage.setItem("chats.lastOpened", key); } catch { /* the event still opens it */ }
  window.dispatchEvent(new CustomEvent("nook-open-chat", { detail: key }));
  if (everywhere) emit("open-chat", key).catch(() => {});
}
