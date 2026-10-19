// De companion: de server op de computer (Instellingen › Companion) en de telefoonkant op Android.
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

export interface DigestItem {
  id: string;
  kind: "approval" | "question";
  title: string;
  detail: string;
  /** De telefoon mag dit toestaan (laag risico), of de vraag heeft één onderdeel. */
  canAllow: boolean;
  options: string[];
}

export interface SessionDigest {
  id: string;
  title: string;
  agent: string;
  attention: string;
  folder: string;
  branch?: string;
  updated: number;
  excerpt: string;
  items: DigestItem[];
}

export type ServerState =
  | { state: "stopped" }
  | { state: "listening"; port: number }
  | { state: "failed"; message: string };

export interface CompanionInfo {
  server: boolean;
  client: boolean;
  enabled: boolean;
  state: ServerState | null;
  computerName: string;
  hosts: string[];
  devices: { id: string; name: string; pairedAt: string; lastSeen: string | null; push: boolean }[];
  pairing: { url: string; qrSvg: string; host: string; until: string } | null;
}

export interface ClientView {
  phase: "unpaired" | "pairing" | "connected" | "offline";
  reason: string;
  macName: string;
  host: string;
  sessions: SessionDigest[];
  notice: string | null;
  deviceName?: string;
}

export const companion = {
  info: () => invoke<CompanionInfo>("companion_info"),
  setEnabled: (enabled: boolean) => invoke<CompanionInfo>("companion_set_enabled", { enabled }),
  beginPairing: (host?: string) => invoke<CompanionInfo>("companion_begin_pairing", { host }),
  cancelPairing: () => invoke<CompanionInfo>("companion_cancel_pairing"),
  removeDevice: (id: string) => invoke<CompanionInfo>("companion_remove_device", { id }),

  client: () => invoke<ClientView>("companion_client"),
  pair: (link: string, name: string) => invoke<ClientView>("companion_client_pair", { link, name }),
  unpair: () => invoke<ClientView>("companion_client_unpair"),
  refresh: () => invoke<ClientView>("companion_client_refresh"),
  decide: (session: string, item: string, allow: boolean) => invoke<ClientView>("companion_client_decide", { session, item, allow }),
  answer: (session: string, item: string, text: string) => invoke<ClientView>("companion_client_answer", { session, item, text }),
  send: (session: string, text: string) => invoke<ClientView>("companion_client_send", { session, text }),
  stop: (session: string) => invoke<ClientView>("companion_client_stop", { session }),
  clearNotice: () => invoke<void>("companion_client_clear_notice"),
  visible: (visible: boolean) => invoke<void>("companion_client_visible", { visible }),
  onClient: (cb: (v: ClientView) => void): Promise<UnlistenFn> => listen<ClientView>("companion-client", (e) => cb(e.payload)),
};

const rank: Record<string, number> = { approval: 0, input: 1, failed: 2, limited: 3, working: 4, ready: 5, idle: 6, finished: 7 };

/** Wat jou nodig heeft eerst, dan het nieuwste (zoals de iPhone-app). */
export function sortSessions(sessions: SessionDigest[]): SessionDigest[] {
  return [...sessions].sort((a, b) => {
    const [x, y] = [rank[a.attention] ?? 9, rank[b.attention] ?? 9];
    return x !== y ? x - y : b.updated - a.updated;
  });
}

export function attentionWord(attention: string): string {
  switch (attention) {
    case "approval": return "Wacht op toestemming";
    case "input": return "Heeft een vraag";
    case "failed": return "Mislukt";
    case "limited": return "Limiet bereikt";
    case "working": return "Aan het werk";
    case "ready": return "Klaar";
    case "finished": return "Afgerond";
    default: return "Rust";
  }
}

/** De kleur bij een toestand: amber wacht op jou, coral is fout, mint is klaar. */
export function attentionColor(attention: string): string {
  switch (attention) {
    case "approval": case "input": case "limited": return "var(--amber)";
    case "failed": return "var(--coral)";
    case "working": return "var(--paper)";
    case "ready": return "var(--mint)";
    default: return "var(--text3)";
  }
}

/** Stoppen heeft alleen zin als de sessie bezig is of op jou wacht. */
export function canStop(attention: string): boolean {
  return attention === "working" || attention === "approval" || attention === "input";
}

/** Een koppelcode herkennen voordat hij naar Rust gaat (die controleert hem echt). */
export function looksLikePairingLink(text: string): boolean {
  return /^nook:\/\/pair\/?\?/.test(text.trim());
}
