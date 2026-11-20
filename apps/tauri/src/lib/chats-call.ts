// Calling from the Chats tab (`ChatCalls`, `ChatCallTracker` on the Mac): which chat apps support voice/video calls,
// formatting the call duration clock, and web fallbacks when the desktop app or backend command is unavailable.

export type CallKind = "voice" | "video";

export type CallPhase =
  | { phase: "calling" }
  | { phase: "live"; since: string }
  | { phase: "ended"; seconds: number; at: string };

export interface CallDevices {
  microphone: string | null;
  speaker: string | null;
  camera: string | null;
}

export interface ActiveCallSnapshot {
  id: string;
  chatKey: string;
  chatId: string;
  app: string;
  appName: string;
  name: string;
  kind: CallKind;
  direct: boolean;
  started: string;
  phase: CallPhase;
  devices: CallDevices;
}

/** Chat apps that hold calls at all on Windows (no Messages/FaceTime). Mirrors `nook_core::chats::call::CALLING_APPS`. */
export const CALLING_APPS = new Set([
  "whatsapp", "telegram", "instagram", "messenger", "signal", "slack", "discord", "teams", "googlechat", "snapchat",
  "viber", "wechat", "line", "skype", "element", "threema", "wire", "x",
]);

/** Chat apps that also hold group calls. Mirrors `nook_core::chats::call::GROUP_CALLING_APPS`. */
export const GROUP_CALLING_APPS = new Set([
  "whatsapp", "telegram", "messenger", "signal", "slack", "discord", "teams", "googlechat", "element", "wire", "line",
  "wechat", "viber", "skype",
]);

/** Whether this chat's app holds calls Nook can start (`AppModel.canCallChat`). */
export function canCallChat(app: string, isGroup: boolean): boolean {
  return isGroup ? GROUP_CALLING_APPS.has(app) : CALLING_APPS.has(app);
}

/** "0:00", "4:07", "1:02:33" (`ChatCallTracker.clock`). */
export function callClock(seconds: number): string {
  const total = Math.max(0, Math.floor(seconds));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const rest = total % 60;
  return hours > 0
    ? `${hours}:${String(minutes).padStart(2, "0")}:${String(rest).padStart(2, "0")}`
    : `${minutes}:${String(rest).padStart(2, "0")}`;
}

/** Website fallback for opening a chat app when no desktop link opens it (matches macOS `MessagingApps.builtIn`). */
const WEB_URLS: Record<string, string> = {
  whatsapp: "https://web.whatsapp.com",
  telegram: "https://web.telegram.org",
  instagram: "https://instagram.com",
  messenger: "https://messenger.com",
  signal: "https://signal.org",
  slack: "https://app.slack.com",
  discord: "https://discord.com",
  teams: "https://teams.microsoft.com",
  googlechat: "https://chat.google.com",
  snapchat: "https://snapchat.com",
  viber: "https://viber.com",
  wechat: "https://wechat.com",
  line: "https://line.me",
  skype: "https://skype.com",
  element: "https://app.element.io",
  threema: "https://threema.ch",
  wire: "https://wire.com",
  x: "https://x.com",
  linkedin: "https://linkedin.com",
};

export function callAppUrl(app: string): string | null {
  return WEB_URLS[app] ?? null;
}

/** Elapsed seconds to show on the call card for its current phase. */
export function callElapsed(call: ActiveCallSnapshot, nowMs: number): number {
  if (call.phase.phase === "ended") return Math.max(0, call.phase.seconds);
  const anchor = call.phase.phase === "live" ? Date.parse(call.phase.since) : Date.parse(call.started);
  if (Number.isNaN(anchor)) return 0;
  return Math.max(0, Math.floor((nowMs - anchor) / 1000));
}
