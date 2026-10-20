// De platformdiensten: muziek, stem, Flow, de Notetaker, meekijken en meedenken, Vandaag, geluiden en het schermdeel.
// Zelfde vormen als de Rust-structs (serde, camelCase).
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import type { PlannedAction } from "./types";

export type EnergyPace = "full" | "light" | "paused";
export type EnergyReason = "displayAsleep" | "hot" | "lowPowerMode" | "busy" | "away" | "battery" | "saver";

export interface EnergyView {
  plan: { pace: EnergyPace; reasons: EnergyReason[] };
  status: string;
}

export interface QuietState {
  silent: boolean;
  excludedFromCapture: boolean;
  hidden: boolean;
  situation: { sharing: boolean; meeting: boolean };
}

export interface QuietView {
  state: QuietState;
  status: string;
}

/// The reason in a few words, as the Rust side writes it (`EnergyReason::text`).
export const energyReasons: Record<EnergyReason, string> = {
  displayAsleep: "je scherm slaapt",
  hot: "je computer is warm",
  lowPowerMode: "energiebesparing staat aan",
  busy: "je computer is druk bezig",
  away: "je bent even weg",
  battery: "je computer draait op de accu",
  saver: "je koos voor Zuinig",
};

/// What the screen reading does right now (Settings › Assistant): off, paused and why, the windows it holds, or
/// nothing. The pause comes before the windows: held windows must not hide that nothing is read right now.
export function screenLine(enabled: boolean, windows: string[], energy: EnergyView | null): string {
  if (!enabled) return "Uit";
  const reason = energy?.plan.reasons[0];
  if (energy?.plan.pace === "paused" && reason) return `Gepauzeerd: ${energyReasons[reason]}`;
  if (windows.length) return windows.slice(0, 4).join(" · ");
  return "niets gelezen";
}

export interface NowPlaying {
  app: string;
  title: string;
  artist: string;
  album: string;
  playing: boolean;
  artwork: string | null;
  position: number | null;
  duration: number | null;
  shuffle: boolean | null;
  repeat: boolean | null;
  volume: number | null;
  canSeek: boolean;
}

export type SpeechEngine = "local" | "windows" | "openai" | "groq";

export interface ServicePrefs {
  clipboard: boolean;
  speechEngine: SpeechEngine;
  whisperModel: string;
  thinkAlongMuted: Record<string, string>;
  screenPartShortcut: string;
  notesShortcut: string;
  files: boolean;
  callNotes: boolean;
  recapSeen: string;
}

export interface VoiceInfo {
  whisper: string | null;
  openaiKey: boolean;
  groqKey: boolean;
  speechEngineReady: string | null;
}

export interface VoiceEvent {
  phase: "listening" | "working" | "idle" | "error";
  text: string;
  level: number;
  error: string | null;
  result: string | null;
  seconds: number;
}

export type FlowStyle = "verbatim" | "natural" | "polished";

export interface FlowSettings {
  enabled: boolean;
  key: string;
  cleanup: boolean;
  promptMode: boolean;
  translateTo: string;
  keepHistory: boolean;
  appStyles: Record<string, FlowStyle>;
}

export interface FlowEntry {
  id: string;
  date: string;
  text: string;
  app: string | null;
  words: number;
  seconds: number;
}

export interface FlowView {
  settings: FlowSettings;
  dictionary: string;
  history: FlowEntry[];
  words: number;
  wordsPerMinute: number;
  minutesSaved: number;
  streak: number;
}

export type NoteStatus = "recording" | "processing" | "ready" | "failed";

export interface NoteSummary {
  id: string;
  title: string;
  start: string;
  minutes: number;
  status: NoteStatus;
  summary: string | null;
  todos: number;
  error: string | null;
}

export interface NoteLive {
  recording: boolean;
  seconds: number;
  level: number;
  lines: number;
  last: string;
  systemAudio: boolean;
  problem: string | null;
}

export interface Nudge {
  id: string;
  line: string;
  body: string;
  app: string;
  window: string;
  actions: PlannedAction[];
  steps: string[];
  offers: string[];
  date: number;
}

export interface TodayItem {
  id: string;
  kind: "nudge" | "recording" | "note" | "recap";
  title: string;
  subtitle: string;
  action: string;
}

export interface WeekSummary {
  start: string;
  activeSeconds: number;
  sessions: number;
  prompts: number;
  commands: number;
  edits: number;
  linesAdded: number;
  linesRemoved: number;
  allowed: number;
  denied: number;
  questions: number;
  topProject: string | null;
  topAgent: string | null;
  busiestDay: string | null;
  busiestSeconds: number;
}

export interface RecapView {
  label: string;
  summary: WeekSummary;
  duration: string;
  busiest: string | null;
}

export interface ScreenStatus {
  available: boolean;
  status: string;
  windows: string[];
  displays: number;
}

export const services = {
  prefs: () => invoke<ServicePrefs>("services_prefs"),
  savePrefs: (prefs: ServicePrefs) => invoke<ServicePrefs>("save_services_prefs", { prefs }),
  voiceInfo: () => invoke<VoiceInfo>("voice_info"),

  nowPlaying: () => invoke<NowPlaying | null>("now_playing"),
  media: (action: "playPause" | "next" | "previous") => invoke<void>("media_command", { action }),
  seek: (seconds: number) => invoke<void>("media_seek", { seconds }),
  shuffle: (on: boolean) => invoke<void>("media_shuffle", { on }),
  repeat: (on: boolean) => invoke<void>("media_repeat", { on }),
  volume: (percent: number) => invoke<void>("media_volume", { percent }),

  voiceStart: () => invoke<void>("voice_start"),
  voiceFinish: () => invoke<void>("voice_finish"),
  voiceCancel: () => invoke<void>("voice_cancel"),
  voiceFollow: (nookId: string, messageId: string) => invoke<void>("voice_follow", { nookId, messageId }),
  speak: (text: string) => invoke<void>("speak_text", { text }),
  speakStop: () => invoke<void>("speak_stop"),

  flowView: () => invoke<FlowView>("flow_view"),
  saveFlowSettings: (settings: FlowSettings) => invoke<void>("save_flow_settings", { settings }),
  saveFlowDictionary: (text: string) => invoke<void>("save_flow_dictionary", { text }),
  clearFlowHistory: () => invoke<void>("flow_clear_history"),
  flowCancel: () => invoke<void>("flow_cancel"),
  flowHandsFree: () => invoke<void>("flow_hands_free"),

  notes: () => invoke<NoteSummary[]>("notes_list"),
  noteMarkdown: (id: string) => invoke<string | null>("note_markdown", { id }),
  deleteNote: (id: string) => invoke<void>("note_delete", { id }),
  toggleNote: () => invoke<void>("note_toggle"),
  noteLive: () => invoke<NoteLive>("note_live"),

  lookAlong: () => invoke<void>("look_along"),
  nudge: () => invoke<Nudge | null>("nudge_current"),
  answerNudge: (id: string, answer: "yes" | "open" | "no" | "mute" | "later") => invoke<void>("nudge_answer", { id, answer }),
  asideExpand: (large: boolean) => invoke<void>("aside_expand", { large }),
  asideHide: () => invoke<void>("aside_hide"),
  asideShow: () => invoke<void>("aside_show"),
  screenStatus: () => invoke<ScreenStatus>("screen_status"),
  energyStatus: () => invoke<EnergyView>("energy_status"),
  /// `watching`: Settings shows the line, so the situation is read even with "change nothing" for both.
  quietStatus: (watching: boolean) => invoke<QuietView>("quiet_status", { watching }),

  partBegin: () => invoke<void>("screen_part_begin"),
  partImage: () => invoke<string | null>("screen_part_image"),
  partFinish: (x: number, y: number, w: number, h: number, copy: boolean) => invoke<void>("screen_part_finish", { x, y, w, h, copy }),
  partCancel: () => invoke<void>("screen_part_cancel"),

  today: () => invoke<TodayItem[]>("today_items"),
  recap: () => invoke<RecapView>("recap_view"),
  soundFile: (name: string) => invoke<string | null>("sound_file", { name }),
  openSoundsFolder: () => invoke<string>("open_sounds_folder"),
};

export const serviceEvents = {
  onNowPlaying: (cb: (n: NowPlaying | null) => void): Promise<UnlistenFn> => listen<NowPlaying | null>("now-playing", (e) => cb(e.payload)),
  onVoice: (cb: (e: VoiceEvent) => void): Promise<UnlistenFn> => listen<VoiceEvent>("voice-state", (e) => cb(e.payload)),
  onFlow: (cb: (e: VoiceEvent) => void): Promise<UnlistenFn> => listen<VoiceEvent>("flow-state", (e) => cb(e.payload)),
  onNudge: (cb: (n: Nudge | null) => void): Promise<UnlistenFn> => listen<Nudge | null>("nudge", (e) => cb(e.payload)),
  onNoteLive: (cb: (n: NoteLive) => void): Promise<UnlistenFn> => listen<NoteLive>("note-live", (e) => cb(e.payload)),
  onEnergy: (cb: (v: EnergyView) => void): Promise<UnlistenFn> => listen<EnergyView>("energy-plan", (e) => cb(e.payload)),
  onQuiet: (cb: (s: QuietState) => void): Promise<UnlistenFn> => listen<QuietState>("quiet-changed", (e) => cb(e.payload)),
  onAttachImage: (cb: (img: { mediaType: string; base64: string }) => void): Promise<UnlistenFn> =>
    listen<{ mediaType: string; base64: string }>("attach-image", (e) => cb(e.payload)),
};

/// 75 → "1:15".
export function clock(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const r = String(s % 60).padStart(2, "0");
  return h ? `${h}:${String(m).padStart(2, "0")}:${r}` : `${m}:${r}`;
}

/// Waar het nummer nu is: de laatst gemelde positie plus de tijd sindsdien, als het speelt.
export function estimatedPosition(info: NowPlaying, since: number, now: number): number {
  const base = info.position ?? 0;
  if (!info.playing) return base;
  const estimate = base + Math.max(0, (now - since) / 1000);
  return info.duration ? Math.min(info.duration, estimate) : estimate;
}
