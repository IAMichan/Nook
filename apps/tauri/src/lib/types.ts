// Dezelfde vormen als de Rust-structs in nook-core (serde, camelCase).
import type { AutocompleteSettings } from "./autocomplete";
import type { ActionField, ChatChart, MailDraft, Recovery, RetrievalStep, SourceScope } from "./brain";
import type { TaskStep } from "./task-steps";

export type ProviderId =
  | "claude" | "claudeCode" | "codexCLI" | "geminiCLI" | "grokCLI" | "kimiCLI" | "vibeCLI" | "openai" | "gemini" | "grok" | "mistral" | "groq"
  | "openrouter" | "deepseek" | "qwen" | "moonshot" | "ollama" | "lmstudio";

export interface ProviderInfo {
  id: ProviderId;
  title: string;
  isLocal: boolean;
  needsKey: boolean;
  /** Thinks through a coding agent's own sign-in (Claude Code, Codex, Gemini CLI, Grok, Kimi Code, Vibe), no key. */
  isSubscription: boolean;
  cliCommand: string | null;
  loginCommand: string | null;
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
  /** What Nook may do by itself from the chat (`brain::access`); null until chosen, when `autoRunSafe` decides. */
  nookAccess?: "ask" | "small" | "more" | null;
  placement: "top" | "floating";
  floatX: number | null;
  floatY: number | null;
  screenChoice: string;
  accentHex: number;
  hideWhenIdle: boolean;
  panelLarge: boolean;
  /** Quitting asks first while a session is at work (Settings › General › Confirmations). */
  confirmQuit: boolean;
  /** The bar shows at the top of the screen; off, only a shortcut or the tray opens it. */
  showBar: boolean;
  /** Settings › Notifications: how chats, Nook and suggestions show, apps switched off, quiet hours (the agents' style is
   *  `agentNotice`). */
  noticeRules: {
    styles: Record<string, "card" | "strip" | "system" | "off">;
    apps: Record<string, boolean>;
    quietHours: { from: number; to: number; allowsUrgent: boolean } | null;
    quietWhileWatching: boolean;
  };
  /** The main window opens when Nook starts (Settings › General › Bar & windows). */
  openWindowAtLaunch: boolean;
  /// How large an agent notice is in the bar: a card ("detailed") or one line in the bar ("compact").
  agentNotice: "detailed" | "compact" | "system" | "off";
  sounds: boolean;
  /** Which sound each moment plays, by sound name: "" or missing is Nook's own (your file first), "none" is silent,
   *  anything else a system sound's name (`services::sounds`). */
  soundChoices?: Record<string, string>;
  speakAnswers: boolean;
  wakeWord: boolean;
  webSearch: boolean;
  liveScreen: boolean;
  screenWithEveryQuestion: boolean;
  localOnlySources: string[];
  /** Settings › Brain › Screen work: "ollama:<model>" or "lmstudio:<model>", "" for none. */
  screenBrain: string;
  /** The screen brain writes the chosen brain a filtered note instead of answering itself. */
  screenBrainRelays: boolean;
  evidenceFirst: boolean;
  checkAnswers: boolean;
  selectionAsk: boolean;
  useMemory: boolean;
  learnFromChats: boolean;
  onboardingDone: boolean;
  demoData: boolean;
  shortcuts: Record<string, string>;
  /// GitHub organizations ("acme") and repositories ("acme/web") whose pull requests show under Agents › Pull requests.
  watchedPullRequests: string[];
  quietWhileSharing: QuietBehavior;
  quietInMeetings: QuietBehavior;
  quietUseCalendar: boolean;
  hideFromCaptures: boolean;
  showInScreenshots: boolean;
  energyMode: EnergyMode;
  /// Autocomplete Anywhere (Settings › Aanvullen). Off by default.
  autocomplete: AutocompleteSettings;
  /** What Home's greeting calls you; empty greets without a name. */
  userName: string;
  /** Feature ids pinned to Home, in order; `null` shows the default set. */
  homeEssentials: string[] | null;
  /** Dismissed inbox item ids, with when they were dismissed (ISO). */
  inboxDismissed: Record<string, string>;
  /** Snoozed inbox item ids, with when they come back (ISO). */
  inboxSnoozed: Record<string, string>;
  /** Which sources may interrupt: "all" | "work" | "deep" | "off_hours". */
  focusMode: string;
  /** When the inbox was last looked at (ISO); "Catch me up" summarises what came after. */
  inboxSeenAt: string | null;
  /// Start an installed local brain (Ollama, LM Studio) that is not running.
  startLocalBrain: boolean;
  trayHintShown: boolean;
  mainWindow: { x: number; y: number; width: number; height: number; maximized: boolean } | null;
  /** The windows' look (Settings › Appearance); old files stay dark. */
  theme: "system" | "light" | "dark";
  /** How much room text and rows get. */
  density: "compact" | "comfortable" | "spacious";
  /** The theme in dark and in light (`lib/palette.ts`): a built-in id or an imported theme's. */
  darkTheme: string;
  lightTheme: string;
  /** Imported VS Code themes (`ColorTheme` in `lib/palette.ts`). */
  customThemes: unknown[];
  /** Colors set one by one over the themes, per appearance: token to "#rrggbb". */
  colorOverrides: { dark: Record<string, string>; light: Record<string, string> };
  /** Added and removed lines: green and red, or blue and orange. */
  diffColors: "redGreen" | "blueOrange";
  /** Math in answers and Markdown is typeset (KaTeX, offline). */
  renderMath: boolean;
  /** Markdown shows its style in the composer as you type; what is sent stays plain Markdown. */
  richComposer: boolean;
  /** Nook offers above the field what it can do for what a conversation says; nothing runs until Do it. */
  suggestChatActions: boolean;
  /** The model of the brain's service that looks for those; empty is the brain's own. */
  actionSuggestionModel: string;
  /** Nook's face (`NookLook` on the Mac). */
  nookLook: NookLook;
  /** Nook as a buddy: the small moments (hello, waking up, a giggle, a blush). */
  buddyMoments: boolean;
  /** The default answer style (Settings › Instructions). */
  answerStyle: "standard" | "concise" | "explanatory" | "formal" | "casual";
  /** The user's own standing instructions, sent with every question. */
  instructions: string;
}

/// What Nook does while you share your screen or sit in a meeting.
export type QuietBehavior = "normal" | "quiet" | "hideFromShare" | "hide";

/// How much Nook does by himself on battery or a busy computer.
export type EnergyMode = "automatic" | "saver" | "full";

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
  /// Noticing a screen share or a call.
  shareDetection: boolean;
  /// Leaving Nook's windows out of screen sharing and screenshots (Windows).
  captureExclusion: boolean;
  /// Autocomplete Anywhere: suggestions while typing in any app (Windows).
  autocomplete: boolean;
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
  excerpt?: string | null;
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
  /** The filtered note this answer was written from: exactly what left this computer of what stays on it. */
  privateBrief?: string;
  charts: ChatChart[];
  /** The plan Nook works through (`update_plan`), as a checklist above the answer. */
  tasks?: TaskStep[];
  mails: MailDraft[];
  actions: PlannedAction[];
  planState: PlanState | null;
  actionStates: StepState[];
  actionIncluded: boolean[];
  actionProblems: string[][];
  offers: string[];
  recovery: Recovery | null;
  attachment: string | null;
  /** A question an automation asked: shown as a "Scheduled run" line, not as a bubble the user typed. */
  scheduled?: boolean;
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
  /** The automation whose run this conversation is. */
  scheduledTask?: string | null;
  /** Questions waiting for the answer that is being written (absent when none wait). */
  queue?: MessageQueue;
}

export interface QueuedQuestion {
  id: string;
  text: string;
  created: string;
  imageCount: number;
  documentName?: string;
}

export interface MessageQueue {
  messages: QueuedQuestion[];
  isHeld: boolean;
}

export interface ConversationSummary {
  id: string;
  title: string;
  updated: string;
  status: ConversationStatus;
  preview: string;
  pinned: boolean;
  archived: boolean;
  /** The automation whose run this conversation is. */
  scheduledTask?: string | null;
  /** What the list's hover card says of it (`ConversationCard`). */
  card?: ConversationCard;
}

/** What a Nook did, for the hover card in the list (`NookHoverCard` on the Mac). */
export interface ConversationCard {
  created: string;
  messages: number;
  tasksDone: number;
  tasksTotal: number;
  task: string | null;
  taskActive: boolean;
  mailTo: string | null;
  chart: string | null;
  sources: string[];
  request: string;
  summary: string;
  scope: string | null;
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
  /** The source the step acts on, for its icon and name (`StepSourceIcon`). */
  source?: string | null;
}

export interface StreamEvent {
  nookId: string;
  messageId: string;
  text: string;
}

export interface ChatTerminal {
  folder: string;
  id: string;
}

/** Nook's face (Settings › Appearance): eyes, mouth, gloss, glow and blush (`NookLook` on the Mac). */
export interface NookLook {
  eyes: "round" | "bars" | "dots";
  mouth: "expressive" | "line" | "none";
  gloss: boolean;
  glow: boolean;
  cheeks: boolean;
}

/** The ready-made looks (`NookLook.presets`). */
export const LOOK_PRESETS: { id: "minimal" | "classic" | "playful"; look: NookLook }[] = [
  { id: "minimal", look: { eyes: "dots", mouth: "none", gloss: false, glow: false, cheeks: false } },
  { id: "classic", look: { eyes: "bars", mouth: "none", gloss: true, glow: true, cheeks: true } },
  { id: "playful", look: { eyes: "round", mouth: "expressive", gloss: true, glow: true, cheeks: true } },
];
