// Active call tracking for the Chats tab (`ChatCallCenter` on the Mac): starts a voice or video call via Tauri's
// `chat_call_*` commands, listens for `chat-call-changed` updates, and falls back gracefully in preview mode when the
// backend commands are not registered.
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { openUrl } from "@tauri-apps/plugin-opener";
import { appName, type ChatEntry } from "./chats-list";
import { callAppUrl, canCallChat, type ActiveCallSnapshot, type CallKind } from "./chats-call";

class ActiveCallStore {
  call = $state<ActiveCallSnapshot | null>(null);
  /** Wall clock updated once a second ONLY while a call shows, so idle views keep no timer running. */
  now = $state(Date.now());
  private started = false;
  private ticker: ReturnType<typeof setInterval> | null = null;

  /** Connects to backend state and events once. Safe to call in preview mode without Tauri. */
  init() {
    if (this.started) return;
    this.started = true;
    invoke<ActiveCallSnapshot | null>("chat_call_active")
      .then((snap) => this.setCall(snap))
      .catch(() => {});
    listen<ActiveCallSnapshot | null>("chat-call-changed", (e) => {
      this.setCall(e.payload);
    }).catch(() => {});
  }

  private setCall(snap: ActiveCallSnapshot | null) {
    this.call = snap;
    this.now = Date.now();
    if (snap && !this.ticker) {
      this.ticker = setInterval(() => {
        this.now = Date.now();
      }, 1000);
    } else if (!snap && this.ticker) {
      clearInterval(this.ticker);
      this.ticker = null;
    }
  }

  /** Starts a voice or video call from a chat (`AppModel.startChatCall`). */
  async start(entry: ChatEntry, kind: CallKind) {
    if (!canCallChat(entry.app, entry.isGroup)) return;
    this.init();
    try {
      const snap = await invoke<ActiveCallSnapshot>("chat_call_start", { key: entry.key, kind });
      this.setCall(snap);
    } catch {
      // Graceful fallback when running in preview mode or before the command is registered:
      // still open the chat app's web URL (if available) and show the local tracking card.
      const url = callAppUrl(entry.app);
      if (url) {
        openUrl(url).catch(() => {});
      }
      this.setCall({
        id: `local-${Date.now()}`,
        chatKey: entry.key,
        chatId: entry.id,
        app: entry.app,
        appName: appName(entry.app),
        name: entry.name,
        kind,
        direct: false,
        started: new Date().toISOString(),
        phase: { phase: "calling" },
        devices: { microphone: null, speaker: null, camera: null },
      });
    }
  }

  /** Stops following the active call (`ChatCallCenter.dismiss`). */
  dismiss() {
    this.setCall(null);
    invoke("chat_call_dismiss").catch(() => {});
  }

  /** Brings or opens the app the call (or chat) is in (`ChatCallCenter.showApp` / `openChatApp`). */
  async openApp(appId?: string) {
    const target = appId ?? this.call?.app;
    if (!target) return;
    try {
      await invoke("chat_call_open_app", { appId: target });
    } catch {
      const url = callAppUrl(target);
      if (url) {
        openUrl(url).catch(() => {});
      }
    }
  }
}

export const activeCall = new ActiveCallStore();
