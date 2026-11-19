// Updates for a downloaded Nook on Windows and Linux (`AppUpdater` on the Mac): the calls to `src-tauri/src/updates.rs`
// and one shared state, so the footer button and Settings › Maintenance show the same thing.
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

export type UpdatePhase = "unavailable" | "idle" | "checking" | "upToDate" | "available" | "installing" | "readyToRestart" | "failed";
export type UpdateStep = "download" | "verify" | "install" | "restart";
export type UpdateChannel = "stable" | "beta";

export interface IncomingChange {
  title: string;
  pullRequest: number;
  author: string;
  date: string | null;
}

export interface UpdateStatus {
  phase: UpdatePhase;
  unavailableReason: string | null;
  version: string;
  installKind: { kind: "windowsSetup" | "windowsMsi" | "appImage" | "deb" | "package" | "unsupported"; path?: string };
  step: UpdateStep | null;
  progress: number | null;
  candidate: { version: string; title: string; page: string | null; changes: IncomingChange[]; changeCount: number; size: number } | null;
  manual: { version: string; page: string | null } | null;
  lastChecked: string | null;
  checking: boolean;
  problem: string | null;
  failure: string | null;
  channel: UpdateChannel;
  autoCheck: boolean;
  /** What an administrator (or NOOK_DISABLE_UPDATES) allows. */
  policy: { disabled: boolean; betaDisabled: boolean; source: "environment" | "administrator" | "unreadable" | null };
  receipt: { from: string; to: string; changes: IncomingChange[]; installedAt: string } | null;
}

export const STEPS: UpdateStep[] = ["download", "verify", "install", "restart"];

/// What the footer button shows; null when there is nothing to say.
export function footerState(s: UpdateStatus | null): "available" | "installing" | "ready" | "failed" | "updated" | null {
  if (!s) return null;
  if (s.phase === "readyToRestart") return "ready";
  if (s.phase === "installing") return "installing";
  if (s.phase === "failed") return "failed";
  if (s.phase === "available" && s.candidate) return "available";
  if (s.receipt) return "updated";
  return null;
}

export const updater = $state<{ status: UpdateStatus | null }>({ status: null });

let started = false;
/// Loads the status once and follows the `update-changed` event; every caller shares it.
export function startUpdates() {
  if (started) return;
  started = true;
  invoke<UpdateStatus | null>("update_status").then((s) => (updater.status = s)).catch(() => {});
  listen<UpdateStatus>("update-changed", (e) => (updater.status = e.payload)).catch(() => {});
}

const keep = (s: UpdateStatus | null) => {
  if (s) updater.status = s;
  return s;
};

export const updates = {
  check: () => invoke<UpdateStatus | null>("update_check").then(keep),
  install: () => invoke<void>("update_install"),
  /// After an update waited for working agents: they stop now and can be resumed after the restart.
  restart: () => invoke<void>("update_restart"),
  setPrefs: (prefs: { autoCheck?: boolean; channel?: UpdateChannel }) => invoke<UpdateStatus | null>("update_set_prefs", prefs).then(keep),
  dismiss: () => invoke<UpdateStatus | null>("update_dismiss").then(keep),
};
