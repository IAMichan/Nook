// Gedeelde staat van de interface (Svelte 5 runes). Elk venster (balk en hoofdvenster) heeft zijn eigen exemplaar;
// de waarheid staat in Rust en komt binnen via events.
import { api, events } from "./api";
import type { AppInfo, Conversation, ConversationSummary, Settings } from "./types";

class NookState {
  info = $state<AppInfo | null>(null);
  settings = $state<Settings | null>(null);
  nooks = $state<ConversationSummary[]>([]);
  activeId = $state<string | null>(null);
  active = $state<Conversation | null>(null);
  /// Tekst die nu binnenkomt, per bericht-id.
  streaming = $state<Record<string, string>>({});
  error = $state<string | null>(null);

  waiting = $derived(this.nooks.filter((n) => n.status === "waiting").length);
  working = $derived(this.nooks.filter((n) => n.status === "working").length);

  async start() {
    try {
      [this.info, this.settings] = await Promise.all([api.appInfo(), api.getSettings()]);
      this.activeId = await api.activeNook();
      await Promise.all([this.refreshList(), this.load(this.activeId)]);
    } catch (e) {
      this.error = String(e);
    }
    events.onStream((e) => {
      if (e.nookId === this.activeId) this.streaming[e.messageId] = e.text;
    });
    events.onNookUpdated(async (id) => {
      await this.refreshList();
      if (id === this.activeId) await this.load(id);
    });
    events.onSettings(async (s) => {
      this.settings = s;
      this.info = await api.appInfo();
    });
    events.onNewNook(() => this.newNook());
  }

  async refreshList() {
    this.nooks = await api.nooks(false);
  }

  /// Counts `load` calls, so an answer that arrives after a newer one (a click on another Nook while an update for the
  /// old one was still loading) is dropped instead of switching the chat back.
  private loadSeq = 0;

  async load(id: string | null) {
    if (!id) return;
    const seq = ++this.loadSeq;
    const conv = await api.nook(id);
    if (seq !== this.loadSeq) return;
    this.activeId = id;
    this.active = conv;
    // Klaar met streamen: de opgeslagen tekst is leidend.
    for (const m of conv?.messages ?? []) if (!m.streaming) delete this.streaming[m.id];
  }

  async select(id: string) {
    await this.load(id);
    await this.refreshList();
  }

  async newNook() {
    const id = await api.newNook();
    await this.select(id);
  }

  /// De actieve Nook (maakt er een als er nog geen is).
  async ensureActive(): Promise<string> {
    if (!this.activeId) this.activeId = await api.activeNook();
    return this.activeId;
  }

  async ask(text: string, images?: { mediaType: string; base64: string }[], attachment?: { name: string; text: string }) {
    this.error = null;
    try {
      await this.ensureActive();
      await api.ask(this.activeId!, text, images, attachment);
    } catch (e) {
      this.error = String(e);
    }
  }

  async stop() {
    if (this.activeId) await api.stop(this.activeId);
  }

  async saveSettings(patch: Partial<Settings>) {
    if (!this.settings) return;
    this.settings = await api.saveSettings({ ...this.settings, ...patch });
    this.info = await api.appInfo();
  }

  get busy(): boolean {
    return this.nooks.find((n) => n.id === this.activeId)?.status === "working";
  }
}

export const nook = new NookState();

export function accentCss(hex: number): string {
  return `#${hex.toString(16).padStart(6, "0")}`;
}

/// Donkere tekst op een lichte accentkleur, wit op een donkere (zelfde regel als NookTheme.onIris).
export function onAccent(hex: number): string {
  const ch = (v: number) => {
    const c = (v & 0xff) / 255;
    return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
  };
  const lum = 0.2126 * ch(hex >> 16) + 0.7152 * ch(hex >> 8) + 0.0722 * ch(hex);
  return lum > 0.45 ? "#0B0A12" : "#ffffff";
}

export function relativeTime(iso: string): string {
  const diff = (Date.now() - new Date(iso).getTime()) / 1000;
  if (diff < 60) return "zojuist";
  if (diff < 3600) return `${Math.floor(diff / 60)} min`;
  if (diff < 86400) return `${Math.floor(diff / 3600)} u`;
  if (diff < 7 * 86400) return `${Math.floor(diff / 86400)} d`;
  return new Date(iso).toLocaleDateString("nl-NL", { day: "numeric", month: "short" });
}
