// Koppelingen: dezelfde vormen als de Rust-structs in nook_core::connectors en de commando's in
// src-tauri/src/commands/connectors.rs. Geheimen komen nooit terug, alleen of ze er zijn.
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

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

export interface WhatsAppSettings {
  enabled: boolean;
  gateway: "gowa" | "openwa";
  url: string;
  port: number;
  notify: boolean;
  markReadOnReply: boolean;
  muteGroups: boolean;
  ignored: string[];
  autoStart: boolean;
  gowaPath: string;
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

export interface WhatsAppMessage {
  id: string;
  chat: string;
  senderName: string;
  text: string;
  date: string;
  fromMe: boolean;
}

export interface WhatsAppConversation {
  id: string;
  name: string;
  isGroup: boolean;
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
  ci: "unknown" | "pending" | "passing" | "failing";
}

export interface AccountPullRequests {
  id: string;
  name: string;
  login: string;
  mine: PullRequestItem[];
  reviews: PullRequestItem[];
  error: string | null;
  errorKind: ErrorKind | null;
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
  githubPullRequests: () => invoke<AccountPullRequests[]>("github_pull_requests"),

  mcpPaste: (text: string) => invoke<Pasted>("mcp_paste", { text }),
  mcpAdd: (name: string, target: string, remote: boolean, secrets: string) => invoke<string>("mcp_add", { name, target, remote, secrets }),
  mcpRemove: (id: string) => invoke<void>("mcp_remove", { id }),
  mcpSetEnabled: (id: string, enabled: boolean) => invoke<void>("mcp_set_enabled", { id, enabled }),
  mcpTest: (id: string) => invoke<McpTool[]>("mcp_test", { id }),
  mcpConnectService: (service: string) => invoke<void>("mcp_connect_service", { service }),
  mcpSignIn: (id: string) => invoke<void>("mcp_sign_in", { id }),

  gitlabSave: (host: string, token: string) => invoke<string[]>("gitlab_save", { host, token }),
  gitlabRemove: (host: string) => invoke<string[]>("gitlab_remove", { host }),

  whatsapp: () => invoke<WhatsAppView>("whatsapp_view"),
  whatsappSave: (settings: WhatsAppSettings) => invoke<void>("whatsapp_save", { settings }),
  whatsappCredential: (value: string) => invoke<void>("whatsapp_credential", { value }),
  whatsappTest: () => invoke<string>("whatsapp_test"),
  whatsappChats: () => invoke<WhatsAppConversation[]>("whatsapp_chats"),
  whatsappReply: (chat: string, text: string) => invoke<string>("whatsapp_reply", { chat, text }),
  whatsappMarkRead: (chat: string) => invoke<void>("whatsapp_mark_read", { chat }),
  whatsappIgnore: (chat: string) => invoke<void>("whatsapp_ignore", { chat }),
  whatsappUnmute: () => invoke<void>("whatsapp_unmute"),

  chatAccounts: (nookId: string) => invoke<ChatService[]>("chat_accounts", { nookId }),
  setChatAccounts: (nookId: string, excluded: string[]) => invoke<void>("chat_accounts_set", { nookId, excluded }),

  serviceIcon: (domain: string) => invoke<string | null>("service_icon", { domain }),
};

export const connectorEvents = {
  onChanged: (cb: () => void): Promise<UnlistenFn> => listen("connectors-changed", () => cb()),
  onSignIn: (cb: (e: { service: string; ok: boolean; message: string }) => void): Promise<UnlistenFn> =>
    listen<{ service: string; ok: boolean; message: string }>("connector-signin", (e) => cb(e.payload)),
  onWhatsApp: (cb: (e: WhatsAppArrived) => void): Promise<UnlistenFn> => listen<WhatsAppArrived>("whatsapp-message", (e) => cb(e.payload)),
};

/// Hoe een koppeling ervoor staat, in de woorden van de Mac: werkt, bezig, uit, heeft je nodig, kapot, niet gekoppeld.
export type Health = "working" | "busy" | "off" | "needsYou" | "broken" | "notLinked";

export function health(info: ConnectorInfo | undefined): Health {
  if (!info || !info.configured) return "notLinked";
  if (!info.on) return "off";
  const s = info.status;
  if (s.state.kind === "off" || s.state.kind === "loading") return "busy";
  if (s.state.kind === "ok") return s.needsAttention ? "needsYou" : "working";
  return s.errorKind === "auth" || s.errorKind === "config" ? "needsYou" : "broken";
}

export const healthLabel: Record<Health, string> = {
  working: "Werkt",
  busy: "Bezig…",
  off: "Uit",
  needsYou: "Heeft je nodig",
  broken: "Er gaat iets mis",
  notLinked: "Niet gekoppeld",
};

/// De ene regel onder een naam: wat Nook ziet, of wat er misging.
export function summary(info: ConnectorInfo | undefined, tagline: string): string {
  const h = health(info);
  if (!info || h === "notLinked") return tagline;
  if (h === "off") return "Uitgeschakeld via de schakelaar";
  if (h === "busy") return info.status.headline || "Gegevens ophalen…";
  if (info.status.state.kind === "error") {
    return h === "needsYou" ? `${info.status.state.message} Log opnieuw in of vernieuw je sleutel.` : info.status.state.message;
  }
  return info.status.headline || "Verbonden";
}

export const categories: { id: string; title: string }[] = [
  { id: "development", title: "Ontwikkeling" },
  { id: "work", title: "Werk en notities" },
  { id: "business", title: "Zakelijk" },
  { id: "automation", title: "Automatisering" },
];
