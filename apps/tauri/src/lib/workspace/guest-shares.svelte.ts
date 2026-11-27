// Reactive client store for read-only guest links (`GuestShares` on macOS, AG-81).
// Subscribes to `guest-shares-changed` from Tauri and wraps the five `workspace_guest_*` commands.
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import type { GuestShareInfo, GuestSharesSnapshot } from "./guest-shares";

class GuestSharesStore {
  canShare = $state(false);
  shares = $state<Record<string, GuestShareInfo>>({});
  private started = false;

  start() {
    if (this.started) return;
    this.started = true;
    void this.refresh();
    void listen("guest-shares-changed", () => {
      void this.refresh();
    });
  }

  async refresh(): Promise<void> {
    try {
      const snap = await invoke<GuestSharesSnapshot>("workspace_guest_shares");
      this.canShare = snap.canShare;
      this.shares = snap.shares ?? {};
    } catch {
      // Backend unavailable (e.g. non-Tauri preview/test).
    }
  }

  forRun(runId: string): GuestShareInfo | null {
    this.start();
    return this.shares[runId] ?? null;
  }

  isShared(runId: string): boolean {
    this.start();
    return runId in this.shares;
  }

  async share(runId: string): Promise<string> {
    this.start();
    const link = await invoke<string>("workspace_guest_share", { run: runId });
    await this.refresh();
    return link;
  }

  async stop(runId: string): Promise<void> {
    this.start();
    await invoke("workspace_guest_stop", { run: runId });
    await this.refresh();
  }

  async sendHeld(runId: string, messageId: string): Promise<void> {
    this.start();
    await invoke("workspace_guest_send_held", { run: runId, messageId });
    await this.refresh();
  }

  async dismissHeld(runId: string, messageId: string): Promise<void> {
    this.start();
    await invoke("workspace_guest_dismiss_held", { run: runId, messageId });
    await this.refresh();
  }
}

export const guestShares = new GuestSharesStore();
