// Reactive state for `AgentGovernor` (AG-76): tracks per-session resource throttles
// and lets the user exempt a paused session's child commands (`ResourceWaitStrip`).
import { invoke, isTauri } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

export type AgentThrottle = "normal" | "background" | "paused";

class AgentGovernorStore {
  throttles = $state<Record<string, AgentThrottle>>({});
  private started = false;

  start() {
    if (this.started || !isTauri()) return;
    this.started = true;
    void invoke<Record<string, AgentThrottle>>("workspace_governor_status")
      .then((map) => {
        this.throttles = map ?? {};
      })
      .catch(() => {});
    void listen<Record<string, AgentThrottle>>("agent-governor-changed", (event) => {
      this.throttles = event.payload ?? {};
    });
  }

  throttle(runId: string): AgentThrottle {
    this.start();
    return this.throttles[runId] ?? "normal";
  }

  isPaused(runId: string): boolean {
    return this.throttle(runId) === "paused";
  }

  async letGoOn(runId: string): Promise<void> {
    if (!isTauri()) return;
    const next = { ...this.throttles };
    delete next[runId];
    this.throttles = next;
    await invoke<void>("workspace_governor_let_go_on", { run: runId });
  }
}

export const agentGovernor = new AgentGovernorStore();
