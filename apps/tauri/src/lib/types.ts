// Dezelfde vormen als de Rust-structs in nook-core (serde, camelCase).
import type { ActionField, ChatChart, MailDraft, Recovery, RetrievalStep, SourceScope } from "./brain";

export type ProviderId =
  | "claude" | "claudeCode" | "openai" | "gemini" | "grok" | "mistral" | "groq"
  | "openrouter" | "deepseek" | "qwen" | "moonshot" | "ollama" | "lmstudio";

export interface ProviderInfo {
  id: ProviderId;
  title: string;
  isLocal: boolean;
  needsKey: boolean;
  keyPlaceholder: string;
  keyUrl: string;
  defaultModel: string;
  suggestedModels: string[];
}

export interface Settings {
  appLanguage: string;
  language: string;
  provider: ProviderId;
  providerModels: Record<string, string>;
  autoWatch: boolean;
  autoRunSafe: boolean;
  placement: "top" | "floating";
  floatX: number | null;
  floatY: number | null;
  screenChoice: string;
  accentHex: number;
  hideWhenIdle: boolean;
  panelLarge: boolean;
  sounds: boolean;
  speakAnswers: boolean;
  wakeWord: boolean;
  webSearch: boolean;
  liveScreen: boolean;
  screenWithEveryQuestion: boolean;
  localOnlySources: string[];
  evidenceFirst: boolean;
  checkAnswers: boolean;
  useMemory: boolean;
  learnFromChats: boolean;
  onboardingDone: boolean;
  demoData: boolean;
  shortcuts: Record<string, string>;
}

export interface Capabilities {
  os: "windows" | "linux" | "android" | "macos";
  desktop: boolean;
  screenReading: boolean;
  globalShortcuts: boolean;
  tray: boolean;
  terminals: boolean;
  localAgents: boolean;
  media: boolean;
  screenPart: boolean;
  microphone: boolean;
  localSpeech: boolean;
  speechOutput: boolean;
  wakeWord: boolean;
  flow: boolean;
  systemAudio: boolean;
  openApps: boolean;
  volume: boolean;
  clipboard: boolean;
  notifications: boolean;
  files: boolean;
  /// Uitleg per mogelijkheid die er niet (helemaal) is.
  notes: Record<string, string>;
}

export interface AppInfo {
  version: string;
  capabilities: Capabilities;
  brainLabel: string;
  brainLocal: boolean;
  memoryGb: number;
  brainReady: boolean;
}

export type Tagged<K extends string> = { kind: K; detail?: string };
export type PlanState = Tagged<"pending" | "running" | "done" | "cancelled" | "failed">;
export type StepState = Tagged<"pending" | "approved" | "running" | "done" | "verified" | "failed" | "notRun" | "skipped" | "duplicate">;

export interface PlannedAction {
  id: string;
  tool: string;
  input: Record<string, unknown>;
}

export interface SourceReference {
  number: number;
  sourceId: string;
  title: string;
  detail: string;
  url?: string | null;
}

export interface ChatMessage {
  id: string;
  fromUser: boolean;
  text: string;
  date: string;
  isError: boolean;
  streaming: boolean;
  status: string;
  images: string[];
  sources: string[];
  retrieval: RetrievalStep[];
  references: SourceReference[];
  contextSources: string[];
  scopeLabel: string;
  notices: string[];
  charts: ChatChart[];
  mails: MailDraft[];
  actions: PlannedAction[];
  planState: PlanState | null;
  actionStates: StepState[];
  actionIncluded: boolean[];
  actionProblems: string[][];
  offers: string[];
  recovery: Recovery | null;
  attachment: string | null;
}

export type ConversationStatus = "working" | "waiting" | "unread" | "idle";

export interface Conversation {
  id: string;
  title: string;
  created: string;
  updated: string;
  messages: ChatMessage[];
  unread: boolean;
  pinned: boolean;
  archived: boolean;
  scope: SourceScope | null;
}

export interface ConversationSummary {
  id: string;
  title: string;
  updated: string;
  status: ConversationStatus;
  preview: string;
  pinned: boolean;
  archived: boolean;
}

export interface OpenLoop {
  id: string;
  title: string;
  source: string;
  created: string;
  due: string | null;
}

export interface AuditEntry {
  id: number;
  date: string;
  tool: string;
  args: string;
  result: string;
}

export interface PlanStep {
  tool: string;
  summary: string;
  fields: ActionField[];
  tag: string;
}

export interface StreamEvent {
  nookId: string;
  messageId: string;
  text: string;
}
