// Eén plek voor alle aanroepen naar de Rust-kant, getypt.
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import type {
  AppInfo, AuditEntry, Conversation, ConversationSummary, OpenLoop, PlanStep, ProviderId, ProviderInfo, Settings, StreamEvent,
} from "./types";

export const api = {
  appInfo: () => invoke<AppInfo>("app_info"),
  getSettings: () => invoke<Settings>("get_settings"),
  saveSettings: (settings: Settings) => invoke<Settings>("save_settings", { settings }),
  providers: () => invoke<ProviderInfo[]>("providers"),
  listModels: (providerId: ProviderId) => invoke<string[]>("list_models", { providerId }),
  keyStatus: (providerId: ProviderId) => invoke<string | null>("key_status", { providerId }),
  setKey: (providerId: ProviderId, key: string) => invoke<string | null>("set_key", { providerId, key }),

  nooks: (archived = false) => invoke<ConversationSummary[]>("nooks_list", { archived }),
  searchNooks: (query: string) => invoke<ConversationSummary[]>("nooks_search", { query }),
  nook: (id: string) => invoke<Conversation | null>("nook_get", { id }),
  activeNook: () => invoke<string>("nook_active"),
  newNook: () => invoke<string>("nook_new"),
  deleteNook: (id: string) => invoke<void>("nook_delete", { id }),
  setNookFlags: (id: string, flags: { pinned?: boolean; archived?: boolean }) => invoke<void>("nook_set_flags", { id, ...flags }),

  ask: (nookId: string, text: string, images?: { mediaType: string; base64: string }[], attachment?: { name: string; text: string }) =>
    invoke<string | null>("ask", { nookId, text, images, attachment }),
  stop: (nookId: string) => invoke<void>("stop", { nookId }),
  planSteps: (nookId: string, messageId: string) => invoke<PlanStep[]>("plan_steps", { nookId, messageId }),
  executePlan: (nookId: string, messageId: string, included: boolean[], inputs?: unknown[]) =>
    invoke<void>("execute_plan", { nookId, messageId, included, inputs }),
  cancelPlan: (nookId: string, messageId: string) => invoke<void>("cancel_plan", { nookId, messageId }),

  openLoops: () => invoke<OpenLoop[]>("open_loops"),
  completeLoop: (id: string) => invoke<void>("complete_loop", { id }),
  auditEntries: (query = "") => invoke<AuditEntry[]>("audit_entries", { query }),
  clearAudit: () => invoke<void>("clear_audit"),

  barExpand: (expanded: boolean, notice = false) => invoke<void>("bar_expand", { expanded, notice }),
  barMoved: () => invoke<void>("bar_moved"),
  showMain: (route: string) => invoke<void>("show_main", { route }),
  takeRoute: () => invoke<string | null>("take_route"),
};

export const events = {
  onStream: (cb: (e: StreamEvent) => void): Promise<UnlistenFn> => listen<StreamEvent>("nook-stream", (e) => cb(e.payload)),
  onNookUpdated: (cb: (id: string) => void): Promise<UnlistenFn> => listen<string>("nook-updated", (e) => cb(e.payload)),
  onSettings: (cb: (s: Settings) => void): Promise<UnlistenFn> => listen<Settings>("settings-changed", (e) => cb(e.payload)),
  onNavigate: (cb: (route: string) => void): Promise<UnlistenFn> => listen<string>("navigate", (e) => cb(e.payload)),
  onBarOpen: (cb: (focus: string) => void): Promise<UnlistenFn> => listen<string>("bar-open", (e) => cb(e.payload)),
  onNewNook: (cb: () => void): Promise<UnlistenFn> => listen("new-nook", () => cb()),
};
