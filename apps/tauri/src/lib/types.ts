// Dezelfde vormen als de Rust-structs in nook-core (serde, camelCase).

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
}

export interface AppInfo {
  version: string;
  capabilities: Capabilities;
  brainLabel: string;
  brainLocal: boolean;
}

export type Tagged<K extends string> = { kind: K; detail?: string };
export type PlanState = Tagged<"pending" | "running" | "done" | "cancelled" | "failed">;
export type StepState = Tagged<"pending" | "running" | "done" | "failed" | "skipped" | "duplicate">;

export interface PlannedAction {
  id: string;
  tool: string;
  input: Record<string, unknown>;
}

export interface SourceReference {
  number: number;
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
  references: SourceReference[];
  notices: string[];
  actions: PlannedAction[];
  planState: PlanState | null;
  actionStates: StepState[];
  actionIncluded: boolean[];
  actionProblems: string[][];
  offers: string[];
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
}

export interface StreamEvent {
  nookId: string;
  messageId: string;
  text: string;
}
