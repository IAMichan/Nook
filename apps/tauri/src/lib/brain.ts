// Het brein in de interface: geheugen, lokale modellen, mailconcepten, bijlagen, de bronkiezer en startvragen.
// Dezelfde vormen als de Rust-structs (serde, camelCase).
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import type { Settings } from "./types";

export type ChartKind = "bar" | "line" | "area" | "pie" | "point";

export interface ChartPoint {
  label: string;
  value: number;
}

export interface ChartSeries {
  name: string;
  points: ChartPoint[];
}

export interface ChatChart {
  id: string;
  title: string;
  kind: ChartKind;
  unit: string;
  series: ChartSeries[];
}

export interface MailDraft {
  id: string;
  to: string;
  cc: string;
  subject: string;
  body: string;
  /** draft, sending, sent, opened of failed */
  state: string;
  error: string;
}

export type Outcome = { kind: "running" } | { kind: "found"; detail: number } | { kind: "empty" } | { kind: "failed"; detail: string };

export interface RetrievalStep {
  id: string;
  tool: string;
  sourceId: string | null;
  sourceTitle: string;
  query: string;
  outcome: Outcome;
  cached: boolean;
  references: number[];
}

export type Recovery =
  | { kind: "chooseModel" }
  | { kind: "openLocalServer"; name: string }
  | { kind: "reconnectBrain" }
  | { kind: "reconnectConnection" }
  | { kind: "openSettings" };

export interface ActionField {
  key: string;
  label: string;
  value: string;
  editable: boolean;
  multiline: boolean;
}

export interface SourceScope {
  mode: "automatic" | "only";
  included: string[];
  excluded: string[];
  focus: string[];
}

export interface SourceChoice {
  id: string;
  title: string;
  private: boolean;
}

export interface Attachment {
  name: string;
  text: string;
}

export interface MemoryItem {
  id: string;
  shortId: string;
  kind: "fact" | "preference" | "lesson";
  text: string;
  subject: string;
  origin: "told" | "learned" | "observed" | "imported";
  tool: string | null;
  field: string | null;
  value: string | null;
  strength: number;
  certainty: number;
  created: string;
  updated: string;
  lastUsed: string | null;
  uses: number;
  evidence: number;
  localOnly: boolean;
  pinned: boolean;
}

export interface MemoryOverview {
  items: MemoryItem[];
  learnedWords: number;
  importable: [string, number][];
  localOnlySource: boolean;
}

export interface ModelProfile {
  contextTokens: number;
  maxOutputTokens: number;
  maxTools: number;
}

export interface LocalModelOption {
  id: string;
  title: string;
  sizeGb: number;
  minMemoryGb: number;
  toolSkill: number;
  profile: ModelProfile;
}

export interface ServerModel {
  server: "ollama" | "lmstudio";
  name: string;
}

export type Choice = { kind: "pull"; option: LocalModelOption } | { kind: "server"; model: ServerModel } | { kind: "unavailable" };

export interface Recommendation {
  choice: Choice;
  ready: boolean;
  reason: string;
  title: string;
}

export interface BrainAdvice {
  memoryGb: number;
  recommendations: Recommendation[];
  servers: ServerModel[];
  ollamaRunning: boolean;
}

export interface PullProgress {
  model: string;
  status: string;
  fraction: number | null;
  done: boolean;
  error: string | null;
}

export interface EvalResult {
  id: string;
  question: string;
  answer: string;
  passed: boolean;
  missing: string[];
  forbidden: string[];
}

export const brainApi = {
  memory: () => invoke<MemoryOverview>("memory_overview"),
  memoryAdd: (text: string) => invoke<void>("memory_add", { text }),
  memoryEdit: (id: string, text: string) => invoke<void>("memory_edit", { id, text }),
  memoryDelete: (id: string) => invoke<void>("memory_delete", { id }),
  memoryPin: (id: string, pinned: boolean) => invoke<void>("memory_set_pinned", { id, pinned }),
  memoryLocalOnly: (id: string, localOnly: boolean) => invoke<void>("memory_set_local_only", { id, localOnly }),
  memoryClear: () => invoke<void>("memory_clear"),
  memoryImport: (path: string) => invoke<number>("memory_import", { path }),

  advice: () => invoke<BrainAdvice>("brain_advice"),
  pull: (model: string) => invoke<void>("pull_model", { model }),
  useLocal: (server: string, model: string) => invoke<Settings>("use_local_model", { server, model }),
  test: () => invoke<string>("brain_test"),
  evaluate: () => invoke<EvalResult[]>("brain_eval"),

  mailUpdate: (nookId: string, draft: MailDraft) => invoke<void>("mail_update", { nookId, draft }),
  mailSend: (nookId: string, draft: MailDraft) => invoke<void>("mail_send", { nookId, draft }),
  mailOpen: (nookId: string, draft: MailDraft) => invoke<void>("mail_open", { nookId, draft }),

  readAttachment: (name: string, base64: string) => invoke<Attachment>("read_attachment", { name, base64 }),
  sourceChoices: () => invoke<SourceChoice[]>("source_choices"),
  setScope: (nookId: string, scope: SourceScope | null) => invoke<string>("set_scope", { nookId, scope }),
  suggestions: () => invoke<string[]>("start_suggestions"),
  retryLast: (nookId: string) => invoke<string | null>("retry_last", { nookId }),

  planEdit: (nookId: string, messageId: string, index: number, key: string, value: string) =>
    invoke<string[]>("plan_edit", { nookId, messageId, index, key, value }),
  planInclude: (nookId: string, messageId: string, index: number, included: boolean) =>
    invoke<void>("plan_include", { nookId, messageId, index, included }),
  planRunAgain: (nookId: string, messageId: string, index: number) => invoke<void>("plan_run_again", { nookId, messageId, index }),

  onPull: (cb: (p: PullProgress) => void): Promise<UnlistenFn> => listen<PullProgress>("model-pull", (e) => cb(e.payload)),
  onEval: (cb: (p: [number, number]) => void): Promise<UnlistenFn> => listen<[number, number]>("brain-eval", (e) => cb(e.payload)),
};

/** Leest een bestand als base64 (zonder het "data:"-voorvoegsel). */
export function fileBase64(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result).split(",")[1] ?? "");
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(file);
  });
}

/** Een korte tekst voor een opzoeking: "doorzocht (3)", "niets gevonden", "mislukt: …". */
export function outcomeLabel(outcome: Outcome): string {
  switch (outcome.kind) {
    case "running": return "bezig…";
    case "found": return `doorzocht · ${outcome.detail}`;
    case "empty": return "niets gevonden";
    case "failed": return `mislukt: ${outcome.detail}`;
  }
}
