// Reactive client store for `PullRequestSyncStore` (AG-104): loads persisted PR links per session/branch,
// listens to `"workspace-pr-sync-changed"`, refreshes active sessions from GitHub + timeline mentions,
// and exposes manual link / unlink / state-update actions.
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import {
  emptyPullRequestSyncSnapshot,
  linkedPullRequests,
  sessionBranchRows,
  sessionPullRequests,
  type LinkedPullRequest,
  type PullRequestLink,
  type PullRequestState,
  type PullRequestSyncSnapshot,
  type SessionBranchRow,
  type SessionPullRequestSummary,
} from "./pull-requests";

export const prSyncApi = {
  snapshot: () => invoke<PullRequestSyncSnapshot>("workspace_pr_sync_snapshot"),
  refresh: (opts: { run?: string | null; directory?: string | null; branch?: string | null }) =>
    invoke<PullRequestSyncSnapshot>("workspace_pr_sync_refresh", {
      run: opts.run ?? null,
      directory: opts.directory ?? null,
      branch: opts.branch ?? null,
    }),
  addLink: (sessionKey: string, directory: string | null, reference: string) =>
    invoke<PullRequestLink>("workspace_pr_link_add", { sessionKey, directory, reference }),
  removeLink: (sessionKey: string, linkId: string, url: string) =>
    invoke<void>("workspace_pr_link_remove", { sessionKey, linkId, url }),
  markState: (repository: string, number: number, prState: PullRequestState) =>
    invoke<void>("workspace_pr_mark_state", { repository, number, prState }),
};

class PullRequestSyncStore {
  snapshot = $state<PullRequestSyncSnapshot>(emptyPullRequestSyncSnapshot());
  loaded = $state(false);
  private started = false;
  private unlisten: UnlistenFn | null = null;
  private inFlight = new Set<string>();
  private lastRefresh = new Map<string, number>();

  start() {
    if (this.started) return;
    this.started = true;
    this.reload();
    listen("workspace-pr-sync-changed", () => {
      this.reload();
    })
      .then((fn) => {
        this.unlisten = fn;
      })
      .catch(() => {});
  }

  stop() {
    this.unlisten?.();
    this.unlisten = null;
    this.started = false;
  }

  async reload() {
    try {
      this.snapshot = await prSyncApi.snapshot();
      this.loaded = true;
    } catch {
      // Running outside Tauri (tests/browser preview).
    }
  }

  /** Refreshes one session or folder+branch if its cooldown elapsed (default 45 s, or forced). */
  async refresh(
    opts: { run?: string | null; directory?: string | null; branch?: string | null },
    force = false,
  ): Promise<void> {
    const key = `${opts.run ?? ""}|${opts.directory ?? ""}|${opts.branch ?? ""}`;
    if (!opts.run && !opts.directory) return;
    const now = Date.now();
    if (!force && (this.inFlight.has(key) || now - (this.lastRefresh.get(key) ?? 0) < 45_000)) {
      return;
    }
    this.inFlight.add(key);
    this.lastRefresh.set(key, now);
    try {
      this.snapshot = await prSyncApi.refresh(opts);
      this.loaded = true;
    } catch {
      // Ignore network/offline errors; cached snapshot stays visible.
    } finally {
      this.inFlight.delete(key);
    }
  }

  async addLink(sessionKey: string, directory: string | null, reference: string): Promise<PullRequestLink> {
    const link = await prSyncApi.addLink(sessionKey, directory, reference);
    await this.reload();
    return link;
  }

  async removeLink(sessionKey: string, id: string, url: string): Promise<void> {
    await prSyncApi.removeLink(sessionKey, id, url);
    await this.reload();
  }

  async markState(repository: string, number: number, state: PullRequestState): Promise<void> {
    await prSyncApi.markState(repository, number, state);
    await this.reload();
  }

  forSession(runId: string | null | undefined, directory: string, branch: string | null | undefined): SessionPullRequestSummary {
    return sessionPullRequests(this.snapshot, runId, directory, branch);
  }

  linkedFor(runId: string | null | undefined, directory: string, branch: string | null | undefined): LinkedPullRequest[] {
    return linkedPullRequests(this.snapshot, runId, directory, branch);
  }

  branchRowsFor(runId: string | null | undefined, directory: string, branch: string | null | undefined): SessionBranchRow[] {
    return sessionBranchRows(this.snapshot, runId, directory, branch);
  }
}

export const prSync = new PullRequestSyncStore();
