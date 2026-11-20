// Koppelingen: dezelfde vormen als de Rust-structs in nook_core::connectors en de commando's in
// src-tauri/src/commands/connectors.rs. Geheimen komen nooit terug, alleen of ze er zijn.
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { tr } from "./i18n.svelte";

export type Tone = "good" | "attention" | "bad" | "neutral";
export type ErrorKind = "auth" | "network" | "rateLimited" | "config" | "other";

export type ConnectorState = { kind: "off" | "loading" | "ok" } | { kind: "error"; message: string };

export interface ConnectorItem {
  id: string;
  title: string;
  subtitle: string;
  tone: Tone;
  url: string | null;
  iconDomain: string | null;
}

export interface ConnectorStatus {
  state: ConnectorState;
  headline: string;
  detail: string;
  items: ConnectorItem[];
  updated: string | null;
  needsAttention: boolean;
  errorKind: ErrorKind | null;
}

export interface ConnectorInfo {
  id: string;
  title: string;
  configured: boolean;
  on: boolean;
  status: ConnectorStatus;
}

export interface Field {
  account: string;
  label: string;
  placeholder: string;
  secret: boolean;
}

export interface AccountView {
  id: string;
  label: string;
  title: string;
  identity: string | null;
  hasToken: boolean;
  primary: boolean;
}

export interface ServiceView {
  id: string;
  title: string;
  domain: string;
  category: string;
  tagline: string;
  fields: Field[];
  help: string;
  signupUrl: string | null;
  capabilities: string;
  values: Record<string, string>;
  stored: string[];
  accounts: AccountView[];
}

export interface RemoteView {
  id: string;
  name: string;
  url: string;
  domain: string;
  category: string;
  tagline: string;
  server: string | null;
}

export type Transport = { stdio: { command: string; arguments: string[] } } | { http: { url: string } };

export interface McpServerConfig {
  id: string;
  name: string;
  transport: Transport;
  secretNames: string[];
  enabled: boolean;
  usesOauth: boolean | null;
  serviceId: string | null;
}

export interface McpTool {
  name: string;
  /// The name people read: the server's own title, or the name in words.
  title: string;
  description: string;
  inputSchema: unknown;
  readOnly: boolean;
}

export interface McpView {
  config: McpServerConfig;
  target: string;
  remote: boolean;
  domain: string | null;
  signedIn: boolean;
  tools: McpTool[];
}

export interface LocalSource {
  id: string;
  title: string;
  reason: string;
}

export interface Caps {
  desktop: boolean;
  stdio: boolean;
  browserSignIn: boolean;
  ghCli: boolean;
  deviceFlow: boolean;
}

export interface Overview {
  connectors: ConnectorInfo[];
  services: ServiceView[];
  remote: RemoteView[];
  mcp: McpView[];
  gitlab: string[];
  local: LocalSource[];
  caps: Caps;
}

/** What a GitLab host says about a token: whose it is, that it is refused, or nothing (offline, VPN, not GitLab). */
export type GitLabCheck = { kind: "valid"; username: string } | { kind: "rejected" } | { kind: "unreachable" };

export interface GitLabSaved {
  host: string;
  hosts: string[];
  check: GitLabCheck;
}

export interface Pasted {
  name: string;
  target: string;
  remote: boolean;
  secrets: string;
}

export interface DeviceCode {
  deviceCode: string;
  userCode: string;
  verificationUri: string;
  expiresIn: number;
  interval: number;
}

/** GOWA and OpenWA link WhatsApp itself. */
export type WhatsAppGateway = "gowa" | "openwa";

/** The address each gateway listens on by default. */
export const gatewayAddress: Record<WhatsAppGateway, string> = {
  gowa: "http://127.0.0.1:3000",
  openwa: "http://127.0.0.1:2785",
};

export interface WhatsAppSettings {
  enabled: boolean;
  gateway: WhatsAppGateway;
  url: string;
  port: number;
  notify: boolean;
  markReadOnReply: boolean;
  muteGroups: boolean;
  muteStatus: boolean;
  muteChannels: boolean;
  ignored: string[];
  modes: Record<string, WhatsAppChatMode>;
  autoStart: boolean;
  gowaPath: string;
  /** GOWA's version once Nook installed it. */
  gowaVersion?: string;
  accounts?: { id: string; name: string }[];
  mainName?: string;
}

/** One WhatsApp account as Settings lists it (the first has id ""). */
export interface WhatsAppAccount {
  id: string;
  title: string;
  given: string;
  link: Tagged;
  statusLine: string;
  me: string | null;
  qr: string | null;
  portBusy: boolean;
  port: number | null;
}

/** Where installing GOWA is (`WhatsAppGOWAInstaller.Step`). */
export type GowaStep =
  | { step: "idle" }
  | { step: "checking" }
  | { step: "downloading"; megabytes: number }
  | { step: "verifying" }
  | { step: "installing" }
  | { step: "done"; version: string }
  | { step: "failed"; message: string };

export interface GowaState {
  installed: boolean;
  nooksOwn: boolean;
  version: string;
  step: GowaStep;
  available: boolean;
}

export type Tagged = { kind: string; message?: string };

export interface WhatsAppView {
  link: Tagged;
  webhook: Tagged;
  statusLine: string;
  webhookLine: string;
  qr: string | null;
  me: string | null;
  unread: number;
  hiddenChats: number;
  gowaRunning: boolean;
  settings: WhatsAppSettings;
  hasCredential: boolean;
  desktop: boolean;
}

export type WhatsAppChatMode = "automatic" | "loud" | "muted";
export type WhatsAppChatKind = "person" | "group" | "status" | "channel";
export type WhatsAppReceipt = "failed" | "pending" | "sent" | "delivered" | "read";

/** What a message holds besides text (`kind`), with a document's own name. */
export interface WhatsAppMedia {
  kind: "none" | "image" | "video" | "audio" | "voice" | "document" | "sticker" | "location" | "contact" | "other";
  name?: string | null;
}

export interface WhatsAppMessage {
  id: string;
  chat: string;
  senderName: string;
  text: string;
  media: WhatsAppMedia;
  date: string;
  fromMe: boolean;
  receipt?: WhatsAppReceipt | null;
}

export interface WhatsAppConversation {
  id: string;
  name: string;
  isGroup: boolean;
  kind: WhatsAppChatKind;
  messages: WhatsAppMessage[];
  unread: number;
  lastActivity: string;
}

export interface WhatsAppArrived {
  chat: string;
  name: string;
  preview: string;
  unread: number;
}

/** One chat for its card in the bar, with the files the card already has (a photo with a small picture). */
export interface WhatsAppCard {
  conversation: WhatsAppConversation;
  previews: Record<string, { image: string | null }>;
}

export interface WhatsAppSettingsChat {
  jid: string;
  name: string;
  kind: WhatsAppChatKind;
  mode: WhatsAppChatMode;
  hidden: boolean;
}

export interface ChatService {
  service: string;
  title: string;
  accounts: { id: string; title: string; allowed: boolean }[];
}

export interface PullRequestItem {
  repo: string;
  number: number;
  title: string;
  url: string | null;
  draft: boolean;
  updated: string | null;
  author: string;
  ci: Ci;
  state: "open" | "closed" | "merged";
  review: ReviewDecision;
  /// Comments and reviews on the conversation.
  comments: number;
  additions: number;
  deletions: number;
  /// A merge conflict with the base branch.
  conflicting: boolean;
}

export type ReviewDecision = "none" | "approved" | "changesRequested" | "required";

/// An open issue assigned to you.
export interface IssueItem {
  repo: string;
  number: number;
  title: string;
  url: string | null;
  updated: string | null;
  author: string;
  comments: number;
  labels: string[];
}

export type Ci = "unknown" | "pending" | "passing" | "failing";

export interface AccountPullRequests {
  id: string;
  name: string;
  login: string;
  mine: PullRequestItem[];
  reviews: PullRequestItem[];
  /// The open issues assigned to you.
  issues: IssueItem[];
  error: string | null;
  errorKind: ErrorKind | null;
  /// The other pull requests in the watched organizations and repositories.
  watched: PullRequestItem[];
  /// Watched entries this account could not search.
  unreadable: string[];
}

export interface PullRequestList {
  /// Whether GitHub is connected with at least one account.
  available: boolean;
  accounts: AccountPullRequests[];
}

export const connectorsApi = {
  overview: () => invoke<Overview>("connectors_overview"),
  save: (id: string, values: Record<string, string>) => invoke<ConnectorInfo | null>("connector_save", { id, values }),
  disconnect: (id: string) => invoke<ConnectorInfo | null>("connector_disconnect", { id }),
  toggle: (id: string, on: boolean) => invoke<ConnectorInfo | null>("connector_toggle", { id, on }),
  refresh: (id: string) => invoke<ConnectorInfo | null>("connector_refresh", { id }),

  addAccount: (service: string, label: string) => invoke<AccountView>("account_add", { service, label }),
  renameAccount: (id: string, label: string) => invoke<void>("account_rename", { id, label }),
  removeAccount: (id: string) => invoke<void>("account_remove", { id }),
  setAccountToken: (id: string, token: string) => invoke<ConnectorInfo | null>("account_token", { id, token }),
  githubCli: (account: string) => invoke<ConnectorInfo | null>("github_cli", { account }),
  githubDeviceStart: (account: string) => invoke<DeviceCode>("github_device_start", { account }),
  githubPullRequests: () => invoke<PullRequestList>("github_pull_requests"),

  mcpPaste: (text: string) => invoke<Pasted>("mcp_paste", { text }),
  mcpAdd: (name: string, target: string, remote: boolean, secrets: string) => invoke<string>("mcp_add", { name, target, remote, secrets }),
  mcpRemove: (id: string) => invoke<void>("mcp_remove", { id }),
  mcpSetEnabled: (id: string, enabled: boolean) => invoke<void>("mcp_set_enabled", { id, enabled }),
  mcpTest: (id: string) => invoke<McpTool[]>("mcp_test", { id }),
  mcpConnectService: (service: string) => invoke<void>("mcp_connect_service", { service }),
  mcpSignIn: (id: string) => invoke<void>("mcp_sign_in", { id }),
  repairBySignIn: (service: string) => invoke<void>("connector_repair_sign_in", { service }),

  gitlabSave: (host: string, token: string) => invoke<GitLabSaved>("gitlab_save", { host, token }),
  gitlabCheck: (host: string) => invoke<GitLabCheck>("gitlab_check", { host }),
  gitlabRemove: (host: string) => invoke<string[]>("gitlab_remove", { host }),

  whatsapp: () => invoke<WhatsAppView>("whatsapp_view"),
  whatsappSave: (settings: WhatsAppSettings) => invoke<void>("whatsapp_save", { settings }),
  whatsappCredential: (value: string) => invoke<void>("whatsapp_credential", { value }),
  whatsappTest: () => invoke<string>("whatsapp_test"),
  whatsappChats: () => invoke<WhatsAppConversation[]>("whatsapp_chats"),
  whatsappChatList: () => invoke<WhatsAppConversation[]>("whatsapp_chat_list"),
  whatsappAudio: (chat: string, message: string) => invoke<{ mime: string; base64: string }>("whatsapp_audio", { chat, message }),
  whatsappReply: (chat: string, text: string) => invoke<string>("whatsapp_reply", { chat, text }),
  whatsappMarkRead: (chat: string) => invoke<void>("whatsapp_mark_read", { chat }),
  whatsappIgnore: (chat: string) => invoke<void>("whatsapp_ignore", { chat }),
  whatsappUnmute: () => invoke<void>("whatsapp_unmute"),
  whatsappCard: (chat: string) => invoke<WhatsAppCard | null>("whatsapp_card", { chat }),
  /** Profile photos of these chats as small data URLs, by chat; a chat without one is left out. */
  whatsappAvatars: (chats: string[]) => invoke<Record<string, string>>("whatsapp_avatars", { chats }),
  whatsappCardLoad: (chat: string) => invoke<boolean>("whatsapp_card_load", { chat }),
  whatsappOpenFile: (chat: string, message: string) => invoke<void>("whatsapp_open_file", { chat, message }),
  whatsappAskNook: (chat: string) => invoke<string>("whatsapp_ask_nook", { chat }),
  whatsappMute: (chat: string) => invoke<void>("whatsapp_mute", { chat }),
  whatsappSetMode: (chat: string, mode: WhatsAppChatMode) => invoke<void>("whatsapp_set_mode", { chat, mode }),
  whatsappUnhide: (chat: string) => invoke<void>("whatsapp_unhide", { chat }),
  whatsappSettingsChats: () => invoke<WhatsAppSettingsChat[]>("whatsapp_settings_chats"),
  whatsappAccounts: () => invoke<WhatsAppAccount[]>("whatsapp_accounts"),
  whatsappAccountAdd: (name: string) => invoke<string>("whatsapp_account_add", { name }),
  whatsappAccountRemove: (id: string) => invoke<void>("whatsapp_account_remove", { id }),
  whatsappAccountRename: (id: string, name: string) => invoke<void>("whatsapp_account_rename", { id, name }),
  whatsappAccountRetry: (id: string) => invoke<void>("whatsapp_account_retry", { id }),
  whatsappGowaState: () => invoke<GowaState>("whatsapp_gowa_state"),
  whatsappInstallGowa: (update: boolean) => invoke<void>("whatsapp_install_gowa", { update }),

  chatAccounts: (nookId: string) => invoke<ChatService[]>("chat_accounts", { nookId }),
  setChatAccounts: (nookId: string, excluded: string[]) => invoke<void>("chat_accounts_set", { nookId, excluded }),

  serviceIcon: (domain: string) => invoke<string | null>("service_icon", { domain }),
};

/** Where a chat stands, the same for every app (`ChatReadState`). */
export type ChatReadState = { state: "unread"; count: number } | { state: "readInNook" } | { state: "read" };

/** One message of any chat app, as the shared inbox keeps it (`InboxMessage`). */
export interface InboxMessage {
  id: string;
  sender: string;
  senderId?: string;
  text: string;
  date: string;
  fromMe: boolean;
  media?: { kind: WhatsAppMedia["kind"]; name?: string | null };
  receipt?: WhatsAppReceipt | null;
  mentionsMe?: boolean;
  edited?: boolean;
  deleted?: boolean;
  /** The message this one answers (Nook's id of it). */
  replyTo?: string;
  reactions?: ChatReaction[];
}

/** One emoji on a message and who put it there by name ("" for you). */
export interface ChatReaction { emoji: string; from: string[]; mine: boolean }

/** One chat of any app as a row of the Chats list (`chat_inbox_list`). */
export interface ChatSummary {
  key: string;
  app: string;
  name: string;
  kind: WhatsAppChatKind | null;
  account: string | null;
  read: ChatReadState;
  last: InboxMessage | null;
  activity: string;
  members: number;
  mutedInApp: boolean;
  sends: boolean;
}

export interface ChatThread extends ChatSummary {
  messages: InboxMessage[];
  people: string[];
  hasOlder: boolean;
}

/** The shared inbox of every chat app (`src-tauri/src/chats/inbox.rs`), by the inbox's key of a chat. */
export const chatsApi = {
  list: () => invoke<ChatSummary[]>("chat_inbox_list"),
  thread: (key: string) => invoke<ChatThread | null>("chat_inbox_thread", { key }),
  markRead: (key: string, inApp: boolean) => invoke<void>("chat_inbox_mark_read", { key, inApp }),
  markUnread: (key: string) => invoke<void>("chat_inbox_mark_unread", { key }),
  markAllRead: (keys: string[]) => invoke<void>("chat_inbox_mark_all_read", { keys }),
  send: (key: string, text: string, replyTo: string | null) => invoke<void>("chat_inbox_send", { key, text, replyTo }),
  remove: (key: string) => invoke<void>("chat_inbox_remove", { key }),
  /** A step on one message: edit (text), revoke (for everyone), deleteForMe, react (text the emoji, "" to take it off). */
  message: (key: string, message: string, step: "edit" | "revoke" | "deleteForMe" | "react", text?: string) =>
    invoke<void>("chat_inbox_message", { key, message, step, text: text ?? null }),
  /** Older messages, scrolling back; true while the app has more. */
  older: (key: string) => invoke<boolean>("chat_inbox_older", { key }),
  /** Pin, mute or archive the chat in its app itself (the chat helper's apps). */
  inApp: (key: string, change: { pinned?: boolean; muted?: boolean; archived?: boolean }) =>
    invoke<void>("chat_inbox_in_app", { key, pinned: change.pinned ?? null, muted: change.muted ?? null, archived: change.archived ?? null }),
  sendFile: (key: string, name: string, mime: string, base64: string, caption: string, replyTo: string | null = null, voice = false) =>
    invoke<void>("chat_inbox_send_file", { key, name, mime, base64, caption, replyTo, voice }),
  /** A group's people by name, for "@" in the field. */
  people: (key: string) => invoke<string[]>("chat_inbox_people", { key }),
  /** The chats you owe a reply, every app at once, questions first (`chats::follow_up::chat_owed`). */
  owed: (limit = 3) => invoke<OwedTurn[]>("chat_owed", { limit }),
};

/** A chat whose newest message is someone else's and waits on your answer (`nook_core::chats::follow_up::Turn`). */
export interface OwedTurn { chat: string; app: string; name: string; date: string | null; lastText: string; unread: number }

export const connectorEvents = {
  onChanged: (cb: () => void): Promise<UnlistenFn> => listen("connectors-changed", () => cb()),
  onSignIn: (cb: (e: { service: string; ok: boolean; message: string }) => void): Promise<UnlistenFn> =>
    listen<{ service: string; ok: boolean; message: string }>("connector-signin", (e) => cb(e.payload)),
  onWhatsApp: (cb: (e: WhatsAppArrived) => void): Promise<UnlistenFn> => listen<WhatsAppArrived>("whatsapp-message", (e) => cb(e.payload)),
  onWhatsAppReceipt: (cb: (chat: string) => void): Promise<UnlistenFn> => listen<string>("whatsapp-receipt", (e) => cb(e.payload)),
  /** The shared inbox changed: a chat app brought something, or a chat was read, sent to or removed. */
  onChats: (cb: () => void): Promise<UnlistenFn> => listen("chats-changed", () => cb()),
  /** A notification (or anything in Rust) asks for one chat to open, by its inbox key. */
  onOpenChat: (cb: (key: string) => void): Promise<UnlistenFn> => listen<string>("open-chat", (e) => cb(e.payload)),
};

/// Hoe een koppeling ervoor staat, in de woorden van de Mac: werkt, bezig, uit, heeft je nodig, kapot, niet gekoppeld.
export type Health = "working" | "busy" | "off" | "needsYou" | "broken" | "notLinked";

export function health(info: ConnectorInfo | undefined): Health {
  if (!info || !info.configured) return "notLinked";
  if (!info.on) return "off";
  const s = info.status;
  if (s.state.kind === "off" || s.state.kind === "loading") return "busy";
  // Items that are waiting for you (a review, a failing check) are content, not a broken link: the link works.
  if (s.state.kind === "ok") return "working";
  return s.errorKind === "auth" || s.errorKind === "config" ? "needsYou" : "broken";
}

/// Getters, so each read is in the current interface language.
export const healthLabel: Record<Health, string> = {
  get working() { return tr("Werkt", "Working"); },
  get busy() { return tr("Bezig…", "Busy…"); },
  get off() { return tr("Uit", "Off"); },
  get needsYou() { return tr("Heeft je nodig", "Needs you"); },
  get broken() { return tr("Er gaat iets mis", "Something's wrong"); },
  get notLinked() { return tr("Niet gekoppeld", "Not connected"); },
};

/// De ene regel onder een naam: wat Nook ziet, of wat er misging.
export function summary(info: ConnectorInfo | undefined, tagline: string): string {
  const h = health(info);
  if (!info || h === "notLinked") return tagline;
  if (h === "off") return tr("Uitgeschakeld via de schakelaar", "Turned off with the switch");
  if (h === "busy") return info.status.headline || tr("Gegevens ophalen…", "Fetching data…");
  if (info.status.state.kind === "error") {
    return h === "needsYou" ? tr("{message} Log opnieuw in of vernieuw je sleutel.", "{message} Sign in again or renew your key.", { message: info.status.state.message }) : info.status.state.message;
  }
  return info.status.headline || tr("Verbonden", "Connected");
}

export const categories: { id: string; title: string }[] = [
  { id: "development", get title() { return tr("Ontwikkeling", "Development"); } },
  { id: "work", get title() { return tr("Werk en notities", "Work and notes"); } },
  { id: "business", get title() { return tr("Zakelijk", "Business"); } },
  { id: "automation", get title() { return tr("Automatisering", "Automation"); } },
  { id: "local", get title() { return tr("Op dit apparaat", "On this device"); } },
];

/** How a service gets connected: the one word on every card of the catalogue, so a glance says what a click does. */
export type ConnectMethod = "signIn" | "key" | "mcp";

export const methodLabel: Record<ConnectMethod, string> = {
  get signIn() { return tr("Inloggen", "Sign in"); },
  get key() { return tr("Met sleutel", "With key"); },
  mcp: "MCP",
};

/** Whether a card or row belongs to the chosen category chip (`null` = Alles). */
export function inCategory(selected: string | null, category: string): boolean {
  return selected === null || selected === category;
}

/** Whether a search matches the text of a card or row (case-insensitive, empty matches everything). */
export function matchesQuery(query: string, text: string): boolean {
  const q = query.trim().toLowerCase();
  return !q || text.toLowerCase().includes(q);
}

/** The words for a GitLab host's state, shared by the row and the sheet. `null` while Nook is still asking GitLab. */
export function gitlabHealth(check: GitLabCheck | null): Health {
  if (!check) return "busy";
  return check.kind === "valid" ? "working" : check.kind === "rejected" ? "needsYou" : "broken";
}

export function gitlabDetail(host: string, check: GitLabCheck | null): string {
  if (!check) return tr("{host} · Merge requests op gitlab.com of je eigen host", "{host} · Merge requests on gitlab.com or your own host", { host });
  if (check.kind === "valid") return `${host} · @${check.username}`;
  if (check.kind === "rejected") return tr("GitLab weigert dit token. Controleer of het scope api heeft en niet verlopen is.", "GitLab rejects this token. Check that it has the api scope and hasn't expired.");
  return tr("Nook kon {host} niet bereiken. Het token is bewaard; Nook probeert het opnieuw zodra het nodig is.", "Nook couldn't reach {host}. The token is saved; Nook tries again as soon as it's needed.", { host });
}
