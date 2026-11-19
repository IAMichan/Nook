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
  /** "Always allow" is offered (`agentsTab`). */
  canAlways?: boolean;
  /** Every question of a question item, with multi-select (`agentsTab`). */
  questions?: SessionQuestion[];
}

/** One question of an agent's ask (`SessionQuestion`). */
export interface SessionQuestion {
  id: string; header: string; question: string; options: string[]; previews?: string[]; multiSelect: boolean; allowsOther: boolean;
}

/** The composer's effort, mode and model for the next turns (`SessionControls`). */
export interface SessionControls {
  effort?: string; efforts?: { id: string; name: string }[]; mode?: string; model?: string; models?: { id: string; name: string }[];
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
  /** Where it sits in the Mac's Agents list (`agentsTab`): pinned, settled, snoozed until then. */
  pinned?: boolean;
  settled?: boolean;
  snoozedUntil?: number;
  /** The folder it works in, in full, for "Copy path". */
  path?: string;
  controls?: SessionControls;
  /** Messages that wait in line for after the turn. */
  queued?: { id: string; text: string }[];
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
  devices: PairedDeviceView[];
  /** What the phone that pairs next may do, chosen before the code is shown. */
  pendingScopes: CompanionScope[];
  pairing: { url: string; qrSvg: string; host: string; until: string } | null;
  push: {
    settings: PushSettings;
    keyId: string;
    teamId: string;
    hasKey: boolean;
    canPush: boolean;
    lastResult: string | null;
    /** Sealed through the relay, or straight to Apple with your own APNs key. */
    route: PushRoute;
    /** A relay is in use, so pushes can go through it (Android phones always do). */
    relayReachable: boolean;
    relayActive: boolean;
  } | null;
  /** Reaching this computer away from home and keeping it reachable; null on a phone. */
  away: AwayInfo | null;
}

/** How pushes reach the phones (`RelayPushClient.Route`). */
export type PushRoute = "relay" | "own";
/** A paired phone as Settings shows it: `appVersion` is null until the phone said it; `outdated` means this computer no
 * longer works with its app, `behind` that it works but misses what this Nook added since. */
export interface PairedDeviceView {
  id: string;
  name: string;
  pairedAt: string;
  lastSeen: string | null;
  push: boolean;
  appVersion: string | null;
  outdated: boolean;
  behind: boolean;
  /** What it may do (`CompanionScope` names). */
  scopes: CompanionScope[];
}

/** What a paired phone may do (`CompanionScope`), in the Mac's order. */
export const COMPANION_SCOPES = ["read", "approve", "operate", "chats", "music", "nookChat"] as const;
export type CompanionScope = (typeof COMPANION_SCOPES)[number];

/** `scopes` with `scope` switched on or off, in the Mac's order. */
export function withScope(scopes: readonly CompanionScope[], scope: CompanionScope, on: boolean): CompanionScope[] {
  return COMPANION_SCOPES.filter((s) => (s === scope ? on : scopes.includes(s)));
}

export type RelayStatus =
  | { state: "off" }
  | { state: "invalid" }
  | { state: "connecting" }
  | { state: "connected" }
  | { state: "failed"; message: string };

export type KeepAwakeMode = "off" | "whileWorking" | "always";

export interface AwayInfo {
  relay: { enabled: boolean; own: boolean; address: string };
  /** Nook's own relay in this build; null when only your own relay can be used. */
  nookRelay: string | null;
  relayStatus: RelayStatus;
  keepAwake: KeepAwakeMode;
  /** What is held now and why; null while nothing is. */
  keepAwakeDecision: { hold: "none" | "idle" | "system"; reason: "working" | "phone" | "always" | null } | null;
  backgroundSupported: boolean;
  background: boolean;
  /** This computer has a Tailscale address that phones know. */
  tailscale: boolean;
}

export interface ClientView {
  phase: "unpaired" | "pairing" | "connected" | "offline";
  reason: string;
  /** When the computer last answered the list (seconds since 1970), from the phone's cache (`companion-cache.ts`); set
   * by the interface, not by the client. */
  updatedAt?: number;
  macName: string;
  host: string;
  sessions: SessionDigest[];
  notice: string | null;
  deviceName?: string;
  /** What the computer can do beyond approve, answer, send and stop (`CompanionFeature`). */
  features: string[];
  /** What this phone may do there; null from a computer without scopes (everything). */
  scopes: string[] | null;
  /** The computer's protocol version and the oldest phone it supports; null from one that predates versions. */
  macVersion?: number | null;
  oldestPhone?: number | null;
  /** How the phone reached the computer last: "lan", "tailnet", "internet" or "relay". */
  route?: string;
  /** Every paired computer; one is active. */
  macs?: { id: string; name: string; active: boolean; platform?: string }[];
  /** The other paired computers' sessions, as they had them when last asked. */
  others?: { id: string; name: string; platform?: string; reachable: boolean; sessions: SessionDigest[] }[];
  /** What waits to be sent while the computer is away. */
  outbox?: { id: string; op: string; session?: string | null; conversation?: string | null; item?: string | null; text: string; queuedAt: number }[];
}

export const companion = {
  info: () => invoke<CompanionInfo>("companion_info"),
  setEnabled: (enabled: boolean) => invoke<CompanionInfo>("companion_set_enabled", { enabled }),
  beginPairing: (host?: string) => invoke<CompanionInfo>("companion_begin_pairing", { host }),
  cancelPairing: () => invoke<CompanionInfo>("companion_cancel_pairing"),
  removeDevice: (id: string) => invoke<CompanionInfo>("companion_remove_device", { id }),
  /** What a paired phone may do (`device`), or the phone that pairs next (`device` null). */
  setScopes: (device: string | null, scopes: CompanionScope[]) => invoke<CompanionInfo>("companion_set_scopes", { device, scopes }),
  setPush: (settings: PushSettings) => invoke<CompanionInfo>("companion_set_push", { settings }),
  setPushRoute: (route: PushRoute) => invoke<CompanionInfo>("companion_set_push_route", { route }),
  setApns: (keyId: string, teamId: string, pem?: string) => invoke<CompanionInfo>("companion_set_apns", { keyId, teamId, pem }),
  removeApnsKey: () => invoke<CompanionInfo>("companion_remove_apns_key"),
  pushTest: () => invoke<string>("companion_push_test"),
  setRelay: (enabled: boolean, own: boolean, address: string) => invoke<CompanionInfo>("companion_set_relay", { enabled, own, address }),
  testRelay: () => invoke<number>("companion_test_relay"),
  setKeepAwake: (mode: KeepAwakeMode) => invoke<CompanionInfo>("companion_set_keep_awake", { mode }),
  setBackground: (on: boolean) => invoke<CompanionInfo>("companion_set_background", { on }),

  client: () => invoke<ClientView>("companion_client"),
  pair: (link: string, name: string) => invoke<ClientView>("companion_client_pair", { link, name }),
  unpair: () => invoke<ClientView>("companion_client_unpair"),
  refresh: () => invoke<ClientView>("companion_client_refresh"),
  decide: (session: string, item: string, allow: boolean) => invoke<ClientView>("companion_client_decide", { session, item, allow }),
  answer: (session: string, item: string, text: string) => invoke<ClientView>("companion_client_answer", { session, item, text }),
  send: (session: string, text: string) => invoke<ClientView>("companion_client_send", { session, text }),
  stop: (session: string) => invoke<ClientView>("companion_client_stop", { session }),
  switchTo: (id: string) => invoke<ClientView>("companion_client_switch", { id }),
  discard: (id: string) => invoke<ClientView>("companion_client_discard", { id }),
  pushKeys: () => invoke<{ mac: string; name: string; key: string }[]>("companion_client_push_keys"),
  registerPush: (token: string) => invoke<number>("companion_client_register_push", { token }),
  others: () => invoke<ClientView>("companion_client_others"),
  deny: (session: string, item: string, reason: string) => invoke<ClientView>("companion_client_deny", { session, item, reason }),
  call: (call: ClientCall) => invoke<CallResult>("companion_client_call", { call }),
  clearNotice: () => invoke<void>("companion_client_clear_notice"),
  visible: (visible: boolean) => invoke<void>("companion_client_visible", { visible }),
  onClient: (cb: (v: ClientView) => void): Promise<UnlistenFn> => listen<ClientView>("companion-client", (e) => cb(e.payload)),
  /** What the computer sends over the kept connection: the open session's conversation, the chats, Nook's chats. */
  onLive: (cb: (r: CompanionResponse) => void): Promise<UnlistenFn> => listen<CompanionResponse>("companion-live", (e) => cb(e.payload)),
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

/** The color of a state, as the iPhone draws it (`Theme.color`): amber waits on you, coral failed, blue works, mint is done. */
export function attentionColor(attention: string): string {
  switch (attention) {
    case "approval": case "input": case "limited": return "var(--amber)";
    case "failed": return "var(--coral)";
    case "working": return "var(--blue)";
    case "ready": return "var(--mint)";
    default: return "var(--text3)";
  }
}

export const attentionTint = attentionColor;

/** One word for a row's corner, where the row's title says the rest (`Theme.shortWord`). */
export function shortAttentionWord(attention: string): string {
  switch (attention) {
    case "approval": return tr("Toestemming", "Approval");
    case "input": return tr("Vraag", "Question");
    case "failed": return tr("Mislukt", "Failed");
    case "limited": return tr("Limiet", "Limit");
    case "working": return tr("Aan het werk", "Working");
    case "ready": return tr("Klaar", "Done");
    default: return attentionWord(attention);
  }
}

/** Approval, a question, a failure or a limit: what you have to act on (`Theme.needsYou`). */
export function needsYouState(attention: string): boolean {
  return ["approval", "input", "failed", "limited"].includes(attention);
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
  | "terminals" | "files" | "fileData" | "history" | "entry" | "requestUpdate" | "installUpdate" | "avatars"
  | "watch" | "watchChat" | "watchConversation" | "diff" | "pulls" | "pull" | "pullAct" | "pullWork"
  | "list" | "decide" | "answer" | "send" | "stop" | "options" | "start" | "timeline" | "chats" | "chat" | "ask" | "chatStop"
  | "home" | "usage" | "music" | "inbox" | "inboxChat" | "inboxSend" | "inboxMark" | "manage"
  | "inboxAct" | "inboxOlder" | "inboxMedia" | "inboxInfo" | "inboxSearch"
  | "chatAct" | "chatSearch"
  | "notifySettings" | "notifySet";

export interface LaunchRequest {
  agent: string;
  project: string;
  task: string;
  title?: string;
  plan: boolean;
  worktree: boolean;
  model?: string;
  mainThread?: boolean;
  /** The reasoning effort ("" the agent's default), the access, and the base branch of a new worktree (`agentsTab`). */
  effort?: string;
  permission?: string;
  baseBranch?: string;
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
  images?: { jpeg: string }[];
  pullAction?: PullAction;
  pullWork?: { url: string; agent: string; task: string; model?: string };
  /** The notification settings `notifySet` changes to (`notifySettings`). */
  notify?: NotifySettings;
  items?: string[];
  /** Files with `inboxSend` (`CompanionFile`: the name and the bytes in base64). */
  attachments?: CompanionFile[];
  /** What `inboxAct` does in the chat `item`. */
  chatAction?: InboxAction;
  /** What `chatAct` does to the Nook conversation `conversation`. */
  nookAction?: NookChatAction;
  /** "always" with `decide`; every question's answer by question id with `answer` (`agentsTab`). */
  decision?: string;
  answers?: Record<string, string[]>;
}

/** A file that goes with a message (`CompanionFile`). */
export interface CompanionFile { name: string; data: string }

export interface TerminalDigest { id: string; title: string; running: boolean; output: string }
export interface FolderDigest { path: string; entries?: { name: string; isFolder: boolean; size?: number }[]; text?: string; truncated?: boolean; binary?: boolean }
export interface FileChunk { path: string; offset: number; total: number; data: string }
export interface ChatAvatar { chat: string; version: string; jpeg: string }
export interface InboxReader { name: string; receipt: string; date?: number }

export interface DiffFile { path: string; kind: string; added?: number; removed?: number; patch?: string; truncated: boolean }

export interface PullDigest {
  url: string; repo: string; number: number; title: string; author: string; state: string; ci: string; review: string;
  conflict: boolean; additions?: number; deletions?: number; updated?: number; group: string; headBranch?: string; baseBranch?: string;
  /** The row as the Mac's (`pullActions`): labels with their colors, when it was opened, comments, checks passed of all. */
  labels?: string[]; labelColors?: Record<string, string>; created?: number; comments?: number; checksPassed?: number; checksTotal?: number;
}

/** A comment or a review with words in a pull request's conversation (`PullDetailDigest.Note`). */
export interface PullNote { id: string; author: string; body: string; date?: number; verdict?: string }

/** A thread on a line (`PullDetailDigest.Thread`): `id` is what `reply`, `resolve` and `unresolve` name. */
export interface PullThread {
  id: string; path: string; line?: number; resolved: boolean; outdated: boolean; canReply: boolean; canResolve: boolean; comments: PullNote[];
}

export interface PullDetail {
  url: string; repo: string; number: number; title: string; body: string; author: string; state: string;
  baseBranch: string; headBranch: string; headSHA: string; additions: number; deletions: number; changedFiles: number;
  updated?: number; checks: { name: string; outcome: string; detail: string }[];
  files: { path: string; status: string; additions: number; deletions: number; patch?: string; truncated: boolean; viewed: string }[];
  verdicts: { author: string; approved: boolean }[]; methods: string[]; blocker?: string; verdictsAllowed: boolean; lineComments: boolean; fetched: number;
  /** The Summary's side info, the conversation and what the Mac takes now (`pullActions`); absent from an older Mac. */
  reviewers?: string[]; assignees?: string[]; labels?: string[]; labelColors?: Record<string, string>; milestone?: string;
  issues?: { repo: string; number: number; title: string; open: boolean; url?: string }[];
  autoMerge?: { method?: string; by: string }; behind?: boolean; branchDeleted?: boolean; created?: number;
  actions?: string[]; conversation?: PullNote[]; threads?: PullThread[];
}

/** The computer's notification settings for its phones (`CompanionNotifySettings`, `notifySettings`). */
export interface NotifySettings {
  enabled: boolean; kinds: string[]; onlyWhenAway: boolean; includeTitle: boolean;
  quietFrom?: number | null; quietTo?: number | null; quietAllowsUrgent: boolean;
  registered?: boolean; canSend?: boolean;
}

export interface LineComment { path: string; line: number; side: "LEFT" | "RIGHT"; body: string; startLine?: number }

export interface PullAction {
  kind: "approve" | "requestChanges" | "comment" | "merge" | "viewed" | "unviewed"
    | "close" | "reopen" | "ready" | "draft" | "autoMergeOn" | "autoMergeOff" | "updateBranch" | "rebaseBranch" | "rerunFailed"
    | "deleteBranch" | "note" | "reply" | "resolve" | "unresolve";
  body?: string; comments?: LineComment[]; method?: string; path?: string; head?: string; thread?: string;
}

export interface LaunchOptions {
  agents: {
    id: string; name: string; canPlan: boolean; models?: { id: string; name: string }[]; defaultModel?: string; canMainThread?: boolean;
    efforts?: { id: string; name: string }[]; defaultEffort?: string; permissions?: { id: string; name: string }[]; defaultPermission?: string;
  }[];
  projects: { path: string; name: string; canWorktree: boolean; branches?: string[]; defaultBase?: string }[];
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

export interface ChatDigest {
  id: string; title: string; updated: number; busy: boolean; waiting: boolean; preview: string;
  /** The list's flags as on the Mac (`nookChats`); none from an older computer. */
  pinned?: boolean; archived?: boolean; unread?: boolean; created?: number; scheduled?: boolean;
  /** The questions that wait in line for the answer Nook is writing. */
  queued?: string[];
}

/** What `chatAct` does to one of Nook's conversations (`NookChatAction`). */
export interface NookChatAction { kind: "rename" | "pin" | "archive" | "delete" | "markUnread" | "retry"; text?: string; value?: boolean }

export interface ChatLine { id: string; fromNook: boolean; text: string; date: number; streaming: boolean; status: string; failed: boolean; onMac: boolean }

/** Nook's new words at the end of its last message (`ChatAppend`): `at` counts the Unicode scalars it already had. */
export interface ChatAppend { id: string; at: number; text: string; streaming: boolean; status: string }

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
  /** Which picture the chat has; asked for once with `avatars`. */
  avatar?: string;
  /** What can be done in it besides reading (`InboxAbility` names); none from a computer without `chatActions`. */
  abilities?: string[];
  /** Which list it shows in: "chats", "status" or "channels"; none is "chats". */
  kind?: string;
  /** Pinned in Nook: on top of the list. */
  pinned?: boolean;
  /** Pinned or muted in its app itself. */
  pinnedInApp?: boolean;
  mutedInApp?: boolean;
  /** A group, so its messages say who wrote them. */
  group?: boolean;
  /** The account it is in, while its app has more than one linked. */
  account?: string;
  /** `inboxInfo` has something about the chat itself. */
  hasInfo?: boolean;
}

/** `InboxAbility`: what one chat's app takes. */
export type InboxAbility =
  | "reply" | "react" | "edit" | "delete" | "deleteForMe" | "markReadInApp" | "markUnreadInApp"
  | "pinInApp" | "muteInApp" | "archive" | "deleteChat" | "vote" | "photo" | "file";

/** One thing the phone does in a chat (`InboxAction`), after your own tap. */
export interface InboxAction {
  kind:
    | "react" | "edit" | "delete" | "deleteForMe" | "vote" | "forward" | "pin" | "pinInApp" | "muteInApp"
    | "archive" | "deleteChat" | "remove" | "markReadInNook" | "markReadInApp" | "markUnread";
  message?: string;
  emoji?: string;
  text?: string;
  choices?: string[];
  targets?: string[];
  value?: boolean;
}

export interface InboxPollOption { text: string; votes: number; chosen: boolean }
/** A poll in a chat (`InboxPoll`). */
export interface InboxPoll { question: string; options: InboxPollOption[]; multiple: boolean; counted: boolean }
/** What a chat's app says about the chat itself (`InboxChatInfo`). */
export interface InboxChatInfo {
  chat: string;
  about?: string;
  members: string[];
  admins: string[];
  adminsOnly: boolean;
  details: { key: string; value: string }[];
  blocked: boolean;
  bot: boolean;
  verified: boolean;
}
/** A photo of a chat message (`InboxMedia`). */
export interface InboxMedia { line: string; version: string; jpeg: string }

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
  /** Who has your message and who read it. */
  readers?: InboxReader[];
  /** The emoji you put on it yourself, so tapping one again takes it back. */
  myReactions?: string[];
  edited?: boolean;
  /** Deleted for everyone: it keeps its place and says so. */
  deleted?: boolean;
  /** A centred line (someone joined, the group changed) instead of a bubble. */
  notice?: boolean;
  poll?: InboxPoll;
  /** What its file is: "photo", "video", "gif", "sticker", "audio", "voice" or "file". */
  media?: string;
  /** The version of its photo the computer can send (`inboxMedia`). */
  thumb?: string;
  /** How long an audio or voice message lasts. */
  seconds?: number;
  /** Shown before its app has it back: it can be copied, nothing else. */
  local?: boolean;
}

export interface UsageLimit { label: string; percent: number; resetsAt?: number; note?: string; duration?: number }
export interface UsageAccount { id: string; agent: string; account: string; limits: UsageLimit[] }

export interface HomeDigest {
  lines: { id: string; title: string; subtitle: string; icon: string; tone: string }[];
  events: { id: string; title: string; start: number; end: number; location: string; calendar: string }[];
  suggestions: string[];
  track?: { title: string; artist: string; album: string; app: string; playing: boolean; position: number; duration: number };
  accounts: UsageAccount[];
  /** A new Nook the computer can install (`installUpdate`); absent when there is none. */
  update?: UpdateOffer;
}

/** A Nook update on the computer (`UpdateOffer`): "available", "installing", "readyToRestart" (waits for agents) or "failed". */
export interface UpdateOffer { version: string; state: "available" | "installing" | "readyToRestart" | "failed"; changes: number; progress?: number }

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
  timelineSession?: string;
  timelineAfter?: string;
  inboxChat?: string;
  /** The Nook conversation `messages` or `messageAppend` belong to, on a live update (`watchConversation`). */
  messagesConversation?: string;
  /** `messages` go after this message; none: they are the conversation whole. */
  messagesAfter?: string;
  messageAppend?: ChatAppend;
  revoked?: boolean;
  diff?: DiffFile[];
  pulls?: PullDigest[];
  pull?: PullDetail;
  notify?: NotifySettings;
  terminals?: TerminalDigest[];
  folder?: FolderDigest;
  fileChunk?: FileChunk;
  avatars?: ChatAvatar[];
  cursor?: string;
  timelineBefore?: string;
  entryText?: string;
  /** With `inboxOlder`: `inboxLines` is the page before this message. */
  inboxBefore?: string;
  inboxMedia?: InboxMedia[];
  inboxInfo?: InboxChatInfo;
  /** The chats `inboxSearch` found, the best first. */
  inboxFound?: InboxChatDigest[];
  /** The chat's app may have older messages than these. */
  inboxMore?: boolean;
  /** The Nook conversations `chatSearch` found, and how many wait in the archive (`nookChats`). */
  conversationsFound?: ChatDigest[];
  conversationsArchived?: number;
}

export interface CallResult { view: ClientView; response: CompanionResponse | null }

/** `CompanionFeature` names this phone reads. */
export const Feature = {
  diff: "diff", pullRequests: "pullRequests", images: "images", workspace: "workspace", filePreview: "filePreview",
  history: "history", fullTranscript: "fullTranscript", requestUpdate: "requestUpdate", installUpdate: "installUpdate", avatars: "avatars", appIcons: "appIcons",
  stream: "stream", liveTimeline: "liveTimeline", liveChats: "liveChats", liveConversation: "liveConversation", usage: "usage",
  start: "start", timeline: "timeline", chat: "chat", home: "home", music: "music", inbox: "inbox", manage: "manage", steer: "steer",
  retry: "retry", chatActions: "chatActions", nookChats: "nookChats", agentsTab: "agentsTab", pullActions: "pullActions", notifySettings: "notifySettings",
} as const;

/** What you write while the computer cannot be reached waits on the phone (the outbox) and goes once it answers; a
 * computer that does not answer repeats once (`retry`) gets nothing until it is connected again. */
export function writingWaits(view: Pick<ClientView, "features"> | null | undefined): boolean {
  return has(view, Feature.retry);
}

/** "Offline: no new messages or updates come in", with when the phone heard last (`OfflineStrip` on the iPhone). */
export function offlineWords(view: Pick<ClientView, "updatedAt">): string {
  return view.updatedAt
    ? tr("Offline: er komen geen nieuwe berichten of updates binnen. Laatst bijgewerkt {time}.", "Offline: no new messages or updates come in. Last updated {time}.", { time: messageTime(view.updatedAt) })
    : tr("Offline: er komen geen nieuwe berichten of updates binnen.", "Offline: no new messages or updates come in.");
}

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
  return sessions.filter((s) => s.items.length > 0 || needsYouState(s.attention)).length;
}

/** What kind of computer a pairing is (`CompanionPlatform`): what it said, a Mac when it never did (an older Mac). */
export type ComputerKind = "mac" | "windows" | "linux" | "other";

export function computerKind(platform?: string | null): ComputerKind {
  const p = (platform ?? "").trim().toLowerCase();
  if (!p || p === "macos" || p === "mac" || p === "darwin") return "mac";
  if (p === "windows" || p === "linux") return p;
  return "other";
}

/** The computer's icon: the laptop for a Mac, the monitor for a PC (as the iPhone draws them). */
export function computerIcon(platform?: string | null): string {
  return computerKind(platform) === "mac" ? "laptop" : "monitor";
}

/** "your Mac", or "your computer" for Nook on Windows or Linux: where the computer's name is not known yet. */
export function fallbackComputerName(platform?: string | null, title = false): string {
  if (computerKind(platform) === "mac") return title ? tr("Je Mac", "Your Mac") : tr("je Mac", "your Mac");
  return title ? tr("Je computer", "Your computer") : tr("je computer", "your computer");
}

/** One paired computer in the quick switcher: its state and how much waits there. */
export interface ComputerChoice {
  id: string;
  name: string;
  platform: string;
  active: boolean;
  /** Live (the active one connected) or answered the last check (another); null while not checked yet. */
  reachable: boolean | null;
  waiting: number;
}

/** Every paired computer for the quick switcher, from the live list of the active one and the last check of the others. */
export function computerChoices(view: ClientView): ComputerChoice[] {
  return (view.macs ?? []).map((m) => {
    const other = view.others?.find((o) => o.id === m.id);
    return {
      id: m.id,
      name: m.name,
      platform: m.platform ?? "macos",
      active: m.active,
      reachable: m.active ? view.phase === "connected" : other ? other.reachable : null,
      waiting: needingYou(m.active ? view.sessions : other?.sessions ?? []),
    };
  });
}

/** A computer's line in the switcher: "Live · 2 waiting on you", "Offline", "Online"; empty when there is nothing to say. */
export function computerStatus(c: ComputerChoice): string {
  const state = c.active
    ? c.reachable ? tr("Live", "Live") : tr("Niet verbonden", "Not connected")
    : c.reachable === null ? null : c.reachable ? tr("Online", "Online") : tr("Offline", "Offline");
  const waits = c.waiting > 0 ? tr("{n} wachten op je", "{n} waiting on you", { n: c.waiting }) : null;
  return [state, waits].filter(Boolean).join(" · ");
}

/** Chats with something unread: the count on the Chats tab. */
export function unreadChats(chats: InboxChatDigest[]): number {
  return chats.filter((c) => c.unread > 0 && isChat(c)).length;
}

/** A chat, not an app's status updates or channels (`InboxChatDigest.kind`). */
export function isChat(chat: Pick<InboxChatDigest, "kind">): boolean {
  return !chat.kind || chat.kind === "chats";
}

/** The Chats list: newest first, matching the search and, with `unreadOnly`, only the unread ones. */
export function filterInbox(chats: InboxChatDigest[], query: string, unreadOnly: boolean): InboxChatDigest[] {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean);
  return [...chats]
    .filter((c) => !unreadOnly || c.unread > 0)
    .filter((c) => words.every((w) => `${c.name} ${c.appName} ${c.preview}`.toLowerCase().includes(w)))
    .sort((a, b) => b.last - a.last);
}

/** A greeting for the time of day, as the iPhone's Nook tab says it. */
export function greeting(hour: number): string {
  if (hour >= 5 && hour < 12) return tr("Goedemorgen", "Good morning");
  if (hour >= 12 && hour < 18) return tr("Goedemiddag", "Good afternoon");
  if (hour >= 18 && hour < 23) return tr("Goedenavond", "Good evening");
  return tr("Nog laat bezig?", "Working late?");
}

/** A chat app's color (`ChatAppBadge`). */
export function appColor(app: string): string {
  const colors: Record<string, string> = {
    whatsapp: "#25D366", telegram: "#2AABEE", messages: "#34C759", signal: "#3A76F0", instagram: "#E1306C", messenger: "#0084FF",
    snapchat: "#F5C400", slack: "#E01E5A", discord: "#5865F2", teams: "#6264A7", linkedin: "#0A66C2", mail: "#1A8CFF",
    outlook: "#0078D4", gmail: "#EA4335",
  };
  return colors[app.toLowerCase()] ?? "var(--text2)";
}

/** Up to two initials of a name; "#" for a name without letters (`ChatInitialsFace`). */
export function initials(name: string): string {
  const words = name.split(/\s+/).map((w) => [...w].find((c) => /\p{L}|\p{N}/u.test(c)) ?? "").filter(Boolean);
  return words.slice(0, 2).join("").toUpperCase() || "#";
}

/** A person's tint, the same on every phone for the same name (`ChatPersonTint`: FNV-1a over the lowercased name). */
export function personTint(name: string): string {
  let h = 2166136261;
  for (const b of new TextEncoder().encode(name.toLowerCase())) {
    h ^= b;
    h = Math.imul(h, 16777619) >>> 0;
  }
  return ["var(--mint)", "var(--blue)", "var(--violet)", "var(--music)"][h % 4];
}

/** A row's age: "now", "5 min", "3 h", "2 d". */
export function age(seconds: number, now = Date.now()): string {
  const minutes = Math.floor((now / 1000 - seconds) / 60);
  if (minutes < 1) return tr("nu", "now");
  if (minutes < 60) return tr("{n} min", "{n} min", { n: minutes });
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return tr("{n} u", "{n} h", { n: hours });
  return tr("{n} d", "{n} d", { n: Math.floor(hours / 24) });
}

/** A message's time: today "14:03", another day "12 Oct 14:03". */
export function messageTime(seconds: number, now = Date.now()): string {
  const d = new Date(seconds * 1000);
  const time = d.toLocaleTimeString(locale(), { hour: "2-digit", minute: "2-digit" });
  if (d.toDateString() === new Date(now).toDateString()) return time;
  return `${d.toLocaleDateString(locale(), { day: "numeric", month: "short" })} ${time}`;
}

/** A chat's time in the list: today the clock, then Yesterday, the weekday within a week, the date. */
export function chatTime(seconds: number, now = Date.now()): string {
  const d = new Date(seconds * 1000);
  const today = new Date(now);
  if (d.toDateString() === today.toDateString()) return d.toLocaleTimeString(locale(), { hour: "2-digit", minute: "2-digit" });
  const yesterday = new Date(now - 86_400_000);
  if (d.toDateString() === yesterday.toDateString()) return tr("Gisteren", "Yesterday");
  if (now - d.getTime() < 6 * 86_400_000) return d.toLocaleDateString(locale(), { weekday: "long" });
  return d.toLocaleDateString(locale(), d.getFullYear() === today.getFullYear() ? { day: "numeric", month: "short" } : { day: "numeric", month: "short", year: "numeric" });
}

/** A relative time for a list ("5 min. ago"). */
export function relative(seconds: number, now = Date.now()): string {
  try {
    const diff = Math.round(seconds - now / 1000);
    const f = new Intl.RelativeTimeFormat(locale(), { numeric: "always", style: "short" });
    const a = Math.abs(diff);
    if (a < 60) return f.format(diff, "second");
    if (a < 3600) return f.format(Math.round(diff / 60), "minute");
    if (a < 86400) return f.format(Math.round(diff / 3600), "hour");
    return f.format(Math.round(diff / 86400), "day");
  } catch {
    return shortTime(seconds, now);
  }
}

/** The session actions the phone offers, in the order of the Mac's menu. */
export const SESSION_ACTIONS = ["rename", "snoozeHour", "snoozeEvening", "snoozeTomorrow", "snoozeLimitReset", "snoozeUntil", "unsnooze", "mainThreadOn", "mainThreadOff", "end", "archive"] as const;

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

/** The open session follows live: the computer keeps a connection and sends its conversation as it changes. */
export function followsLive(view: Pick<ClientView, "features"> | null | undefined, feature: string): boolean {
  return has(view, Feature.stream) && has(view, feature);
}

/**
 * The conversation after a live update (`TimelineDelta.apply`): the entries after `after`, or the update whole when it
 * names none. Null when the phone lacks the entry it builds on: then it asks for the whole conversation again.
 */
export function applyTimeline(old: TimelineEntry[] | null, entries: TimelineEntry[], after: string | undefined, limit = 400): TimelineEntry[] | null {
  if (!after) return entries;
  if (!old) return null;
  let index = -1;
  for (let i = old.length - 1; i >= 0; i--) if (old[i].id === after) { index = i; break; }
  if (index < 0) return null;
  return [...old.slice(0, index + 1), ...entries].slice(-limit);
}

/**
 * The Nook conversation after a live update (`ConversationDelta.apply`): Nook's new words added to its last message, or
 * the messages after `after` (the update whole when it names none). Null when the update does not build on what the
 * phone has (it missed one): then it asks for the conversation again.
 */
export function applyConversation(old: ChatLine[] | null, update: Pick<CompanionResponse, "messages" | "messagesAfter" | "messageAppend">): ChatLine[] | null {
  const append = update.messageAppend;
  if (append) {
    const last = old?.[old.length - 1];
    // Counted in code points, as the Mac counts Unicode scalars.
    if (!old || !last || last.id !== append.id || Array.from(last.text).length !== append.at) return null;
    return [...old.slice(0, -1), { ...last, text: last.text + append.text, streaming: append.streaming, status: append.status }];
  }
  if (!update.messages) return old;
  if (!update.messagesAfter) return update.messages;
  if (!old) return null;
  let index = -1;
  for (let i = old.length - 1; i >= 0; i--) if (old[i].id === update.messagesAfter) { index = i; break; }
  return index < 0 ? null : [...old.slice(0, index + 1), ...update.messages];
}

/** The message a phone names to resume the live conversation from (`ConversationDelta.resumePoint`): its last finished one. */
export function resumePoint(lines: ChatLine[] | null | undefined): string | undefined {
  for (let i = (lines?.length ?? 0) - 1; i >= 0; i--) if (!lines![i].streaming) return lines![i].id;
  return undefined;
}

/** Nook writes in the open conversation but nothing came for this long: an update may be stuck, ask again (`CompanionTiming.conversationStall`). */
export const CONVERSATION_STALL = 6_000;

/** Who is typing, as the iPhone says it (`InboxTypist`). */
export function typingText(t: InboxTypist[] | undefined): string | null {
  if (!t?.length) return null;
  if (t.length > 2) return tr("{n} mensen typen…", "{n} people are typing…", { n: t.length });
  if (t.length === 2) return tr("{a} en {b} typen…", "{a} and {b} are typing…", { a: t[0].name, b: t[1].name });
  const who = t[0];
  if (who.kind === "recording") return who.name ? tr("{name} neemt audio op…", "{name} is recording audio…", { name: who.name }) : tr("neemt audio op…", "recording audio…");
  if (who.kind === "uploading") return who.name ? tr("{name} stuurt een bestand…", "{name} is sending a file…", { name: who.name }) : tr("stuurt een bestand…", "sending a file…");
  return who.name ? tr("{name} typt…", "{name} is typing…", { name: who.name }) : tr("typt…", "typing…");
}


/** The protocol this phone speaks (`CompanionProtocol.version`), and the oldest computer it still works with. */
export const PROTOCOL_VERSION = 3;
export const OLDEST_MAC = 1;

/** Every feature this phone knows; a computer that lists more is newer than this app. */
export const KNOWN_FEATURES = [
  "workspace", "start", "timeline", "chat", "home", "usage", "music", "inbox", "liveActivity", "manage", "stream", "routes", "retry",
  "relay", "requestUpdate", "installUpdate", "steer", "liveTimeline", "diff", "images", "clock", "revoke", "foreground", "resume", "pullRequests",
  "attachments", "history", "compression", "filePreview", "liveChats", "avatars", "fullTranscript", "appIcons",
  "liveConversation", "deviceKey", "chatActions", "nookChats", "agentsTab", "pullActions", "notifySettings",
];

export type VersionNotice = "macTooOld" | "phoneTooOld" | "macBehind" | "phoneBehind";

/** Whether this phone and the computer work together, and if one is behind (`CompanionCompatibility`). */
export function versionNotice(view: Pick<ClientView, "macVersion" | "oldestPhone"> | null | undefined): VersionNotice | null {
  if (!view) return null;
  const mac = view.macVersion ?? 1;
  if (mac < OLDEST_MAC) return "macTooOld";
  if (PROTOCOL_VERSION < (view.oldestPhone ?? 1)) return "phoneTooOld";
  if (mac < PROTOCOL_VERSION) return "macBehind";
  if (mac > PROTOCOL_VERSION) return "phoneBehind";
  return null;
}

/** The computer lists features this app does not know: it is newer than the app. */
export function newerMac(view: Pick<ClientView, "features"> | null | undefined): boolean {
  return !!view?.features?.some((f) => !KNOWN_FEATURES.includes(f));
}

/**
 * A file put together from its pieces, in order (`FileAssembly`): a piece that does not follow, or a file that changed
 * size underway, is refused.
 */
export class FileAssembly {
  private parts: Uint8Array[] = [];
  private received = 0;
  total: number | null = null;
  static readonly MAX_BYTES = 8 * 1024 * 1024;

  /** Adds a piece; false when it does not fit what came before. */
  add(chunk: FileChunk): boolean {
    if (chunk.total > FileAssembly.MAX_BYTES || chunk.offset !== this.received || (this.total !== null && chunk.total !== this.total)) return false;
    const bytes = Uint8Array.from(atob(chunk.data), (c) => c.charCodeAt(0));
    this.total = chunk.total;
    this.parts.push(bytes);
    this.received += bytes.length;
    return true;
  }

  get done(): boolean {
    return this.total !== null && this.received >= this.total;
  }

  get next(): number {
    return this.received;
  }

  blob(type: string): Blob {
    return new Blob(this.parts as BlobPart[], { type });
  }
}

/** The earliest and latest moment a session can be snoozed to (`CompanionSnooze`): from 90 seconds on, a month at most. */
export function snoozeRange(now = Date.now()): { min: number; max: number } {
  return { min: now + 90_000, max: now + 31 * 86_400_000 };
}

/** What kind of file a name is, for its icon and how it previews. */
export function fileKind(name: string): "image" | "pdf" | "video" | "audio" | "text" {
  const ext = name.toLowerCase().split(".").pop() ?? "";
  if (["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "svg"].includes(ext)) return "image";
  if (ext === "pdf") return "pdf";
  if (["mp4", "mov", "m4v", "webm"].includes(ext)) return "video";
  if (["mp3", "m4a", "wav", "aac", "ogg", "flac"].includes(ext)) return "audio";
  return "text";
}

/** The route line in the computer's menu and Settings. */
export function routeWords(route: string | undefined): { text: string; icon: string } | null {
  switch (route) {
    case "relay": return { text: tr("Verbonden via je relay", "Connected through your relay"), icon: "globe" };
    case "tailnet": return { text: tr("Verbonden via Tailscale", "Connected over Tailscale"), icon: "shield" };
    case "internet": return { text: tr("Verbonden via internet", "Connected over the internet"), icon: "globe" };
    case "lan": return { text: tr("Verbonden via je lokale netwerk", "Connected over your local network"), icon: "wifi" };
    default: return null;
  }
}

/** What a tap on a notification, or one of its buttons, asks the app to do. */
export interface NotificationAction { action: "open" | "allow" | "deny" | "reply"; mac: string; session: string; item: string | null; text: string | null }

export function parseNotificationAction(json: string | null | undefined): NotificationAction | null {
  if (!json) return null;
  try {
    const v = JSON.parse(json);
    if (!["open", "allow", "deny", "reply"].includes(v.action) || typeof v.session !== "string") return null;
    return { action: v.action, mac: String(v.mac ?? ""), session: v.session, item: typeof v.item === "string" ? v.item : null, text: typeof v.text === "string" ? v.text : null };
  } catch {
    return null;
  }
}

/** A link from the app icon's shortcuts or a widget (`nook://companion/…`). */
export type CompanionLink = { kind: "new" } | { kind: "ask" } | { kind: "chats" } | { kind: "agents" } | { kind: "session"; id: string; mac: string | null };

export function parseCompanionLink(url: string): CompanionLink | null {
  const m = /^nook:\/\/companion\/(new|ask|chats|agents|session)\/?(?:\?(.*))?$/i.exec(url.trim());
  if (!m) return null;
  const what = m[1].toLowerCase();
  if (what !== "session") return { kind: what as "new" | "ask" | "chats" | "agents" };
  const q = new URLSearchParams(m[2] ?? "");
  const id = q.get("id");
  return id && id.length <= 200 ? { kind: "session", id, mac: q.get("mac") } : null;
}

/** The two sessions that need you most, as icon shortcuts. */
export function shortcutSessions(sessions: SessionDigest[], mac: string | undefined): { id: string; title: string; url: string }[] {
  return sortSessions(sessions)
    .filter((s) => s.items.length > 0 || needsYouState(s.attention))
    .slice(0, 2)
    .map((s) => ({ id: s.id, title: s.title, url: `nook://companion/session?id=${encodeURIComponent(s.id)}${mac ? `&mac=${encodeURIComponent(mac)}` : ""}` }));
}

/** What the home screen widgets show (`NookWidgets.kt`): the agents that work or wait on you, waiting ones first, at
 * most five, and each account's limits. */
export function widgetData(sessions: SessionDigest[], accounts: UsageAccount[], mac: string | undefined, now = Date.now()) {
  const waiting = (s: SessionDigest) => s.items.length > 0 || needsYouState(s.attention);
  const agents = sortSessions(sessions)
    .filter((s) => waiting(s) || s.attention === "working")
    .slice(0, 5)
    .map((s) => ({ id: s.id, title: s.title, word: shortAttentionWord(s.items[0]?.kind === "approval" ? "approval" : s.items[0]?.kind === "question" ? "input" : s.attention), waiting: waiting(s) }));
  const limits = accounts.flatMap((a) => a.limits.map((l) => ({ name: `${a.agent}${a.account ? ` · ${a.account}` : ""} · ${l.label}`, percent: Math.round(l.percent), resetsAt: l.resetsAt ?? 0 }))).slice(0, 5);
  return { agents, limits, mac: mac ?? "", updatedAt: now };
}

// The Chats tab as on the Mac (`CompanionChats.swift`, `chatActions`).

/** What one chat takes besides reading (`InboxAbility.parse`); unknown names are left out by the checks. */
export function abilities(chat: Pick<InboxChatDigest, "abilities"> | null | undefined): Set<string> {
  return new Set(chat?.abilities ?? []);
}

/** Where a chat stands, as the Mac's views name it: new, read in Nook only, or read in its app too. */
export type ReadState = "unread" | "readInNook" | "read";
export function readState(chat: Pick<InboxChatDigest, "unread" | "waitsInApp">): ReadState {
  if (chat.unread > 0) return "unread";
  return chat.waitsInApp ? "readInNook" : "read";
}

export type ChatsGroup = "pinned" | "today" | "yesterday" | "week" | "month" | "earlier";
export const CHATS_GROUPS: ChatsGroup[] = ["pinned", "today", "yesterday", "week", "month", "earlier"];

/** Where a chat goes in the list (`ChatsGroup.of`): on top when pinned in Nook, else by its newest message. */
export function chatsGroup(chat: Pick<InboxChatDigest, "pinned" | "last">, now = Date.now()): ChatsGroup {
  if (chat.pinned) return "pinned";
  const today = new Date(now);
  today.setHours(0, 0, 0, 0);
  const day = (n: number) => { const d = new Date(today); d.setDate(d.getDate() - n); return d.getTime() / 1000; };
  if (chat.last >= day(0)) return "today";
  if (chat.last >= day(1)) return "yesterday";
  if (chat.last >= day(7)) return "week";
  if (chat.last >= day(30)) return "month";
  return "earlier";
}

export function groupTitle(group: ChatsGroup): string {
  switch (group) {
    case "pinned": return tr("Vastgezet", "Pinned");
    case "today": return tr("Vandaag", "Today");
    case "yesterday": return tr("Gisteren", "Yesterday");
    case "week": return tr("Deze week", "This week");
    case "month": return tr("Deze maand", "This month");
    case "earlier": return tr("Eerder", "Earlier");
  }
}

/** The list in its groups, each newest first; empty groups left out. */
export function groupChats(chats: InboxChatDigest[], now = Date.now()): { group: ChatsGroup; chats: InboxChatDigest[] }[] {
  const sorted = [...chats].sort((a, b) => b.last - a.last);
  return CHATS_GROUPS.map((group) => ({ group, chats: sorted.filter((c) => chatsGroup(c, now) === group) })).filter((g) => g.chats.length);
}

export interface ChatsFilter {
  query?: string;
  read?: ReadState | null;
  /** One app (`InboxChatDigest.app`), or every app. */
  app?: string | null;
  /** "chats", "status" or "channels"; status and channels show only with an app chosen. */
  kind?: string;
}

/** The Chats list as the Mac filters it: by read state, app and list, and the words of a search. */
export function filterChats(chats: InboxChatDigest[], f: ChatsFilter): InboxChatDigest[] {
  const words = (f.query ?? "").toLowerCase().split(/\s+/).filter(Boolean);
  const kind = f.app ? f.kind ?? "chats" : "chats";
  return chats
    .filter((c) => (c.kind ?? "chats") === kind)
    .filter((c) => !f.app || c.app === f.app)
    .filter((c) => !f.read || readState(c) === f.read)
    .filter((c) => words.every((w) => `${c.name} ${c.appName} ${c.preview}`.toLowerCase().includes(w)));
}

/** The apps in the list, each once, by name. */
export function chatApps(chats: InboxChatDigest[]): { app: string; name: string }[] {
  const seen = new Map<string, string>();
  for (const c of chats) if (!seen.has(c.app)) seen.set(c.app, c.appName);
  return [...seen].map(([app, name]) => ({ app, name })).sort((a, b) => a.name.localeCompare(b.name));
}

/** The lists one app has besides its chats ("status", "channels"), in the Mac's order. */
export function chatKinds(chats: InboxChatDigest[], app: string | null | undefined): string[] {
  if (!app) return [];
  const kinds = new Set(chats.filter((c) => c.app === app).map((c) => c.kind ?? "chats"));
  return kinds.size > 1 || [...kinds].some((k) => k !== "chats") ? ["chats", "status", "channels"].filter((k) => k === "chats" || kinds.has(k)) : [];
}

export function kindTitle(kind: string): string {
  if (kind === "status") return tr("Status", "Status");
  if (kind === "channels") return tr("Kanalen", "Channels");
  return tr("Chats", "Chats");
}

/** The quick reactions of a message's menu, as on the Mac. */
export const QUICK_REACTIONS = ["👍", "❤️", "😂", "😮", "😢", "🙏"];
/** The most chats one message is forwarded to at once. */
export const MAX_FORWARD = 10;
/** How many photos one `inboxMedia` request asks for. */
export const MEDIA_BATCH = 3;
/** What one file may weigh before base64 (`CompanionFile.maxBytes`). */
export const MAX_FILE_BYTES = 150 * 1024;

/** The phone's messages after the computer sent the newest ones again (`InboxPaging.merge`): the older messages you
 * paged back to stay before them. */
export function mergeInboxLines(latest: InboxLine[], kept: InboxLine[]): InboxLine[] {
  const first = latest[0];
  const index = first ? kept.findIndex((l) => l.id === first.id) : -1;
  return index > 0 ? [...kept.slice(0, index), ...latest] : latest;
}

/** An older page (the messages before `before`) put before the phone's messages (`InboxPaging.prepend`). */
export function prependInboxLines(page: InboxLine[], before: string, kept: InboxLine[]): InboxLine[] {
  const index = kept.findIndex((l) => l.id === before);
  if (index < 0) return kept;
  const known = new Set(kept.map((l) => l.id));
  return [...page.filter((l) => !known.has(l.id)), ...kept.slice(index)];
}

/** Your choice after a tap on `option` (`InboxPoll.choice`): one answer replaces, more answers add or take off. */
export function pollChoice(poll: InboxPoll, option: string): string[] {
  const now = poll.options.filter((o) => o.chosen).map((o) => o.text);
  if (now.includes(option)) return now.filter((o) => o !== option);
  return poll.multiple ? [...now, option] : [option];
}

/** The poll with `choice` as your vote, shown at once (`InboxPoll.voting`). */
export function pollVoting(poll: InboxPoll, choice: string[]): InboxPoll {
  return {
    ...poll,
    options: poll.options.map((o) => {
      const now = choice.includes(o.text);
      return { ...o, chosen: now, votes: Math.max(0, o.votes + (now ? 1 : 0) - (o.chosen ? 1 : 0)) };
    }),
  };
}

/** The name of one line of a chat's details (`InboxChatInfo.Detail.key`), in the interface's language. */
export function detailLabel(key: string): string {
  switch (key) {
    case "username": return tr("Gebruikersnaam", "Username");
    case "phone": return tr("Telefoon", "Phone");
    case "email": return tr("E-mail", "Email");
    case "title": return tr("Functie", "Title");
    case "business": return tr("Bedrijf", "Business");
    case "category": return tr("Categorie", "Category");
    case "address": return tr("Adres", "Address");
    case "website": return tr("Website", "Website");
    case "location": return tr("Locatie", "Location");
    case "created": return tr("Aangemaakt", "Created");
    case "createdBy": return tr("Aangemaakt door", "Created by");
    case "memberCount": return tr("Leden", "Members");
    case "ownName": return tr("Eigen naam", "Own name");
    default: return key;
  }
}

/** A detail's value as the phone shows it: `created` is seconds since 1970. */
export function detailValue(key: string, value: string): string {
  if (key !== "created") return value;
  const seconds = Number(value);
  return Number.isFinite(seconds) ? new Date(seconds * 1000).toLocaleDateString(locale(), { day: "numeric", month: "long", year: "numeric" }) : value;
}

/** What a message's file is, in words, for a message without a photo to show. */
export function mediaWord(media: string | undefined): string | null {
  switch (media) {
    case "photo": return tr("Foto", "Photo");
    case "video": return tr("Video", "Video");
    case "gif": return tr("GIF", "GIF");
    case "sticker": return tr("Sticker", "Sticker");
    case "audio": return tr("Audio", "Audio");
    case "voice": return tr("Spraakbericht", "Voice message");
    case "file": return tr("Bestand", "File");
    default: return null;
  }
}

// The Nook tab as on the Mac (`CompanionNookChats.swift`, `nookChats`).

/** Nook is writing, a plan or draft waits for you, or an answer came that you did not read. */
export function nookAsksAttention(c: ChatDigest): boolean {
  return c.busy || c.waiting || c.unread === true;
}

export type NookGroup = "pinned" | "today" | "yesterday" | "previousWeek" | "older";
export const NOOK_GROUPS: NookGroup[] = ["pinned", "today", "yesterday", "previousWeek", "older"];

/** The age group of a moment (seconds since 1970), as the Mac's `DayBucket`: a moment in the future is today. */
export function nookGroup(seconds: number, now = Date.now()): NookGroup {
  const today = new Date(now);
  today.setHours(0, 0, 0, 0);
  const at = seconds * 1000;
  if (at >= today.getTime()) return "today";
  const day = (n: number) => { const d = new Date(today); d.setDate(d.getDate() - n); return d.getTime(); };
  if (at >= day(1)) return "yesterday";
  return at >= day(8) ? "previousWeek" : "older";
}

/** The list as the Mac's Nook tab shows it: what asks for you on top, then the pinned ones, then by age; a scheduled
 * task's run that asks nothing only with a search. Empty groups are left out. */
export function nookSections(chats: ChatDigest[], searching: boolean, now = Date.now()): { attention: ChatDigest[]; groups: { group: NookGroup; chats: ChatDigest[] }[] } {
  const attention = chats.filter(nookAsksAttention);
  const settled = chats.filter((c) => !nookAsksAttention(c) && (c.pinned || searching || !c.scheduled));
  const by = new Map<NookGroup, ChatDigest[]>();
  for (const c of settled) {
    const g = c.pinned ? "pinned" : nookGroup(c.updated, now);
    by.set(g, [...(by.get(g) ?? []), c]);
  }
  return { attention, groups: NOOK_GROUPS.filter((g) => by.has(g)).map((group) => ({ group, chats: by.get(group)! })) };
}

/** Every word of a search in the title or the preview, ignoring case and accents, as the Mac matches them. */
export function nookMatches(c: Pick<ChatDigest, "title" | "preview">, query: string): boolean {
  const fold = (t: string) => t.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase();
  const words = fold(query).split(/\s+/).filter(Boolean);
  const hay = fold(c.title + " " + c.preview);
  return words.every((w) => hay.includes(w));
}

export function nookGroupTitle(g: NookGroup): string {
  switch (g) {
    case "pinned": return tr("Vastgezet", "Pinned");
    case "today": return tr("Vandaag", "Today");
    case "yesterday": return tr("Gisteren", "Yesterday");
    case "previousWeek": return tr("Afgelopen 7 dagen", "Previous 7 days");
    case "older": return tr("Ouder", "Older");
  }
}

/** "Copy conversation": the conversation as Markdown, as the Mac's `ChatExport` writes it. */
export function nookMarkdown(title: string, lines: Pick<ChatLine, "fromNook" | "text">[]): string {
  return ["# " + title, ...lines.filter((l) => l.text).map((l) => `**${l.fromNook ? "Nook" : tr("Jij", "You")}**\n\n${l.text}`)].join("\n\n");
}

/** The Mac's greeting, which says how much is there for you ("Good morning. Two things for you."). */
export function homeGreeting(hour: number, count: number): string {
  const hello = hour < 6 ? tr("Goedenacht", "Good night") : hour < 12 ? tr("Goedemorgen", "Good morning") : hour < 18 ? tr("Goedemiddag", "Good afternoon") : tr("Goedenavond", "Good evening");
  if (count === 0) return tr("{hello}. Niets dat op je wacht.", "{hello}. Nothing waiting for you.", { hello });
  if (count === 1) return tr("{hello}. Eén ding voor je.", "{hello}. One thing for you.", { hello });
  return tr("{hello}. {count} dingen voor je.", "{hello}. {count} things for you.", { hello, count: String(count) });
}
