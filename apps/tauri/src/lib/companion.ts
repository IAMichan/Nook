// De companion: de server op de computer (Instellingen › Companion) en de telefoonkant op Android.
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { locale, tr } from "./i18n.svelte";

export interface DigestItem {
  id: string;
  kind: "approval" | "question";
  title: string;
  detail: string;
  /** De telefoon mag dit toestaan (laag risico), of de vraag heeft één onderdeel. */
  canAllow: boolean;
  options: string[];
  /** A preview per option (a mock-up or code), empty for an option without one. */
  optionPreviews?: string[];
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
  /** False for an agent in a terminal on the computer: decide its approvals here, answer it there. */
  canSend?: boolean;
  model?: string;
  /** What the phone may do to this session besides answering it (`SessionAction`). */
  actions?: string[];
  /** The running turn can take a message right now. */
  canSteer?: boolean;
  limitResetsAt?: number;
  /** The turn that runs now, sent back with Stop and a steer so they reach only that turn. */
  turn?: string;
}

export type ServerState =
  | { state: "stopped" }
  | { state: "listening"; port: number }
  | { state: "failed"; message: string };

export type PushKind = "approval" | "question" | "failed" | "finished" | "limited";

export interface PushSettings {
  enabled: boolean;
  kinds: PushKind[];
  onlyWhenAway: boolean;
  includeTitle: boolean;
  quietFrom?: number | null;
  quietTo?: number | null;
  quietAllowsUrgent: boolean;
}

export interface CompanionInfo {
  server: boolean;
  client: boolean;
  enabled: boolean;
  state: ServerState | null;
  computerName: string;
  hosts: string[];
  devices: { id: string; name: string; pairedAt: string; lastSeen: string | null; push: boolean }[];
  pairing: { url: string; qrSvg: string; host: string; until: string } | null;
  push: { settings: PushSettings; keyId: string; teamId: string; hasKey: boolean; canPush: boolean; lastResult: string | null } | null;
}

export interface ClientView {
  phase: "unpaired" | "pairing" | "connected" | "offline";
  reason: string;
  macName: string;
  host: string;
  sessions: SessionDigest[];
  notice: string | null;
  deviceName?: string;
  /** What the computer can do beyond approve, answer, send and stop (`CompanionFeature`). */
  features: string[];
  /** What this phone may do there; null from a computer without scopes (everything). */
  scopes: string[] | null;
}

export const companion = {
  info: () => invoke<CompanionInfo>("companion_info"),
  setEnabled: (enabled: boolean) => invoke<CompanionInfo>("companion_set_enabled", { enabled }),
  beginPairing: (host?: string) => invoke<CompanionInfo>("companion_begin_pairing", { host }),
  cancelPairing: () => invoke<CompanionInfo>("companion_cancel_pairing"),
  removeDevice: (id: string) => invoke<CompanionInfo>("companion_remove_device", { id }),
  setPush: (settings: PushSettings) => invoke<CompanionInfo>("companion_set_push", { settings }),
  setApns: (keyId: string, teamId: string, pem?: string) => invoke<CompanionInfo>("companion_set_apns", { keyId, teamId, pem }),
  removeApnsKey: () => invoke<CompanionInfo>("companion_remove_apns_key"),
  pushTest: () => invoke<string>("companion_push_test"),

  client: () => invoke<ClientView>("companion_client"),
  pair: (link: string, name: string) => invoke<ClientView>("companion_client_pair", { link, name }),
  unpair: () => invoke<ClientView>("companion_client_unpair"),
  refresh: () => invoke<ClientView>("companion_client_refresh"),
  decide: (session: string, item: string, allow: boolean) => invoke<ClientView>("companion_client_decide", { session, item, allow }),
  answer: (session: string, item: string, text: string) => invoke<ClientView>("companion_client_answer", { session, item, text }),
  send: (session: string, text: string) => invoke<ClientView>("companion_client_send", { session, text }),
  stop: (session: string) => invoke<ClientView>("companion_client_stop", { session }),
  deny: (session: string, item: string, reason: string) => invoke<ClientView>("companion_client_deny", { session, item, reason }),
  call: (call: ClientCall) => invoke<CallResult>("companion_client_call", { call }),
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
    case "approval": return tr("Wacht op toestemming", "Waiting for approval");
    case "input": return tr("Heeft een vraag", "Has a question");
    case "failed": return tr("Mislukt", "Failed");
    case "limited": return tr("Limiet bereikt", "Limit reached");
    case "working": return tr("Aan het werk", "Working");
    case "ready": return tr("Klaar", "Ready");
    case "finished": return tr("Afgerond", "Finished");
    default: return tr("Rust", "Idle");
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

// What the iPhone app does beyond the first version, as `packages/protocol/Sources/CompanionModels.swift` has it. The
// phone only offers what the computer lists in `features`, and what its `scopes` allow.

export type Op =
  | "list" | "decide" | "answer" | "send" | "stop" | "options" | "start" | "timeline" | "chats" | "chat" | "ask" | "chatStop"
  | "home" | "usage" | "music" | "inbox" | "inboxChat" | "inboxSend" | "inboxMark" | "manage";

export interface LaunchRequest {
  agent: string;
  project: string;
  task: string;
  title?: string;
  plan: boolean;
  worktree: boolean;
  model?: string;
  mainThread?: boolean;
}

export interface ClientCall {
  op: Op;
  session?: string;
  item?: string;
  text?: string;
  allow?: boolean;
  conversation?: string;
  launch?: LaunchRequest;
  replyTo?: string;
  steer?: boolean;
  turn?: string;
}

export interface LaunchOptions {
  agents: { id: string; name: string; canPlan: boolean; models?: { id: string; name: string }[]; defaultModel?: string; canMainThread?: boolean }[];
  projects: { path: string; name: string; canWorktree: boolean }[];
  defaultAgent?: string;
  defaultProject?: string;
  defaultPlan: boolean;
  defaultWorktree: boolean;
}

export interface TimelineEntry {
  id: string;
  kind: "user" | "assistant" | "tool" | "change" | "error" | "notice";
  text: string;
  detail?: string;
  date: number;
  failed: boolean;
  output?: string;
  clipped?: boolean;
}

export interface ChatDigest { id: string; title: string; updated: number; busy: boolean; waiting: boolean; preview: string }

export interface ChatLine { id: string; fromNook: boolean; text: string; date: number; streaming: boolean; status: string; failed: boolean; onMac: boolean }

export interface InboxChatDigest {
  id: string;
  app: string;
  appName: string;
  name: string;
  preview: string;
  last: number;
  unread: number;
  canSend: boolean;
  ticks?: string;
  waitsInApp: boolean;
  typing?: InboxTypist[];
}

export interface InboxTypist { name: string; kind: string }

export interface InboxLine {
  id: string;
  text: string;
  date: number;
  sender: string;
  fromMe: boolean;
  attachment?: string;
  ticks?: string;
  quoteSender?: string;
  quoteText?: string;
  reactions: string[];
}

export interface UsageLimit { label: string; percent: number; resetsAt?: number; note?: string; duration?: number }
export interface UsageAccount { id: string; agent: string; account: string; limits: UsageLimit[] }

export interface HomeDigest {
  lines: { id: string; title: string; subtitle: string; icon: string; tone: string }[];
  events: { id: string; title: string; start: number; end: number; location: string; calendar: string }[];
  suggestions: string[];
  track?: { title: string; artist: string; album: string; app: string; playing: boolean; position: number; duration: number };
  accounts: UsageAccount[];
}

/** What the computer sent back, as it came (only the parts the phone reads). */
export interface CompanionResponse {
  id: string;
  ok: boolean;
  error?: string;
  message?: string;
  sessions?: SessionDigest[];
  created?: string;
  launch?: LaunchOptions;
  timeline?: TimelineEntry[];
  conversations?: ChatDigest[];
  messages?: ChatLine[];
  home?: HomeDigest;
  inbox?: InboxChatDigest[];
  inboxLines?: InboxLine[];
  inboxTyping?: InboxTypist[];
}

export interface CallResult { view: ClientView; response: CompanionResponse | null }

/** `CompanionFeature` names this phone reads. */
export const Feature = {
  start: "start", timeline: "timeline", chat: "chat", home: "home", music: "music", inbox: "inbox", manage: "manage", steer: "steer",
} as const;

/** The computer lists this feature. */
export function has(view: Pick<ClientView, "features"> | null | undefined, feature: string): boolean {
  return !!view?.features?.includes(feature);
}

/** `CompanionScope`: read, approve, operate, chats, music, nookChat. A computer without scopes allows everything. */
export function may(view: Pick<ClientView, "scopes"> | null | undefined, scope: string): boolean {
  return !view?.scopes || view.scopes.includes(scope);
}

export type CompanionTab = "home" | "agents" | "chats";

/** The computer's tabs this phone can show: Nook when there is a home or Nook's chat, Chats with the inbox. */
export function tabsFor(view: Pick<ClientView, "features" | "scopes"> | null | undefined): CompanionTab[] {
  const tabs: CompanionTab[] = [];
  if (has(view, Feature.home) || (has(view, Feature.chat) && may(view, "nookChat"))) tabs.push("home");
  tabs.push("agents");
  if (has(view, Feature.inbox) && may(view, "chats")) tabs.push("chats");
  return tabs;
}

/** The Agents list as the iPhone app sorts it: what waits on you, what works, then the rest newest first. */
export function groupSessions(sessions: SessionDigest[]): { waiting: SessionDigest[]; working: SessionDigest[]; rest: SessionDigest[] } {
  const sorted = sortSessions(sessions);
  return {
    waiting: sorted.filter((s) => s.items.length > 0 || s.attention === "approval" || s.attention === "input"),
    working: sorted.filter((s) => s.items.length === 0 && s.attention === "working"),
    rest: sorted.filter((s) => s.items.length === 0 && s.attention !== "approval" && s.attention !== "input" && s.attention !== "working"),
  };
}

/** Every word in the title, folder, branch or agent (as the iPhone's search). */
export function matchesSession(session: SessionDigest, query: string): boolean {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean);
  const hay = [session.title, session.folder, session.branch ?? "", session.agent].join(" ").toLowerCase();
  return words.every((w) => hay.includes(w));
}

/** Sessions waiting on you: the count on the Agents tab. */
export function needingYou(sessions: SessionDigest[]): number {
  return sessions.filter((s) => s.items.length > 0).length;
}

/** Chats with something unread: the count on the Chats tab. */
export function unreadChats(chats: InboxChatDigest[]): number {
  return chats.filter((c) => c.unread > 0).length;
}

/** The Chats list: newest first, matching the search and, with `unreadOnly`, only the unread ones. */
export function filterInbox(chats: InboxChatDigest[], query: string, unreadOnly: boolean): InboxChatDigest[] {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean);
  return [...chats]
    .filter((c) => !unreadOnly || c.unread > 0)
    .filter((c) => words.every((w) => `${c.name} ${c.appName} ${c.preview}`.toLowerCase().includes(w)))
    .sort((a, b) => b.last - a.last);
}

/** A greeting for the time of day, as Nook's home says it. */
export function greeting(hour: number): string {
  if (hour < 6) return tr("Goedenacht", "Good night");
  if (hour < 12) return tr("Goedemorgen", "Good morning");
  if (hour < 18) return tr("Goedemiddag", "Good afternoon");
  return tr("Goedenavond", "Good evening");
}

/** The session actions the phone offers, in the order of the Mac's menu; `snoozeUntil` needs a time picker it lacks. */
export const SESSION_ACTIONS = ["rename", "snoozeHour", "snoozeEvening", "snoozeTomorrow", "snoozeLimitReset", "unsnooze", "mainThreadOn", "mainThreadOff", "end", "archive"] as const;

export function sessionActions(session: SessionDigest): string[] {
  const offered = new Set(session.actions ?? []);
  return SESSION_ACTIONS.filter((a) => offered.has(a) && (a !== "snoozeLimitReset" || !!session.limitResetsAt));
}

export function actionLabel(action: string): string {
  switch (action) {
    case "rename": return tr("Hernoem…", "Rename…");
    case "snoozeHour": return tr("Sluimer een uur", "Snooze for an hour");
    case "snoozeEvening": return tr("Sluimer tot vanavond", "Snooze until this evening");
    case "snoozeTomorrow": return tr("Sluimer tot morgenochtend", "Snooze until tomorrow morning");
    case "snoozeLimitReset": return tr("Sluimer tot de limiet terug is", "Snooze until the limit resets");
    case "unsnooze": return tr("Niet meer sluimeren", "Stop snoozing");
    case "mainThreadOn": return tr("Maak er een hoofdlijn van", "Make it a main thread");
    case "mainThreadOff": return tr("Geen hoofdlijn meer", "No longer a main thread");
    case "end": return tr("Beëindig het proces", "End the process");
    case "archive": return tr("Archiveer", "Archive");
    default: return action;
  }
}

/** The notice after a message: queued behind the turn, or into it. */
export function sendNotice(message: string | undefined): string | null {
  if (message === "queued") return tr("In de wachtrij: na deze beurt.", "Queued: after this turn.");
  if (message === "steered") return tr("Meegegeven aan de lopende beurt.", "Passed into the running turn.");
  if (message === "stale") return tr("Die beurt was al voorbij.", "That turn had already ended.");
  return null;
}

/** Why the computer's Chats list is empty, from `message` on an `inbox` answer. */
export function inboxStatus(message: string | undefined): string | null {
  if (message === "chatsoff") return tr("Op je computer verzamelt Nook nog geen chats. Zet het aan in Nook › Instellingen › Chat-apps.", "Nook doesn't collect chats on your computer yet. Turn it on in Nook › Settings › Chat apps.");
  if (message === "chatsaccess") return tr("Nook mag de meldingen op je computer niet lezen. Geef toegang in Nook › Instellingen › Chat-apps.", "Nook may not read the notifications on your computer. Give access in Nook › Settings › Chat apps.");
  return null;
}

/** "✓", "✓✓" or the read ticks of your own message, as the Chats tab shows them. */
export function ticksMark(ticks: string | undefined): string {
  switch (ticks) {
    case "pending": return "🕓";
    case "sent": return "✓";
    case "delivered": return "✓✓";
    case "read": return "✓✓";
    case "failed": return "!";
    default: return "";
  }
}

/** A short time: today the clock, else the day. */
export function shortTime(seconds: number, now = Date.now()): string {
  const d = new Date(seconds * 1000);
  const today = new Date(now);
  const sameDay = d.toDateString() === today.toDateString();
  return sameDay ? d.toLocaleTimeString(locale(), { hour: "2-digit", minute: "2-digit" }) : d.toLocaleDateString(locale(), { day: "numeric", month: "short" });
}

/** When a limit resets, in words. */
export function resetsIn(resetsAt: number | undefined, now = Date.now()): string {
  if (!resetsAt) return "";
  const minutes = Math.round((resetsAt * 1000 - now) / 60000);
  if (minutes <= 0) return tr("weer vrij", "reset");
  if (minutes < 60) return tr("over {n} min", "in {n} min", { n: minutes });
  const hours = Math.round(minutes / 60);
  if (hours < 48) return tr("over {n} u", "in {n} h", { n: hours });
  return tr("over {n} dagen", "in {n} days", { n: Math.round(hours / 24) });
}
