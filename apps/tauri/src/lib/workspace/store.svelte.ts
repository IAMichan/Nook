// De staat van de werkruimte in de interface (Svelte 5 runes). De waarheid staat in Rust; dit volgt de events.
import { workspaceApi, workspaceEvents, type MessageQueue, type RunEvent, type WorkspaceOverview, type WorkspaceRun } from "./api";

class WorkspaceStore {
  overview = $state<WorkspaceOverview | null>(null);
  /// Tijdlijnen en wachtrijen van sessies die open staan.
  timelines = $state<Record<string, RunEvent[]>>({});
  queues = $state<Record<string, MessageQueue>>({});
  error = $state<string | null>(null);
  private started = false;
  private refreshing: Promise<void> | null = null;
  private loading = new Set<string>();

  runs = $derived(this.overview?.runs ?? []);
  providers = $derived(this.overview?.providers ?? []);
  settings = $derived(this.overview?.settings ?? null);

  async start() {
    if (this.started) return;
    this.started = true;
    await this.refresh();
    workspaceEvents.onChanged(() => {
      this.refresh();
      for (const id of Object.keys(this.queues)) this.loadQueue(id);
    });
    workspaceEvents.onTimeline((id) => {
      if (id in this.timelines) this.loadTimeline(id);
    });
  }

  async refresh() {
    if (this.refreshing) return this.refreshing;
    this.refreshing = (async () => {
      try {
        this.overview = await workspaceApi.overview();
      } catch (e) {
        this.error = String(e);
      } finally {
        this.refreshing = null;
      }
    })();
    return this.refreshing;
  }

  run(id: string): WorkspaceRun | undefined {
    const key = id.replace(/^run:/, "");
    return this.runs.find((r) => r.id === key);
  }

  isRunning(id: string): boolean {
    return this.overview?.running.includes(id.replace(/^run:/, "")) ?? false;
  }

  provider(p: string) {
    return this.providers.find((x) => x.provider === p);
  }

  /// Een stroom events wordt één keer ophalen; komt er tijdens het laden iets bij, dan nog één keer.
  async loadTimeline(id: string) {
    const key = id.replace(/^run:/, "");
    if (this.loading.has(key)) {
      this.loading.add(key + ":again");
      return;
    }
    this.loading.add(key);
    try {
      this.timelines[key] = await workspaceApi.timeline(key);
    } catch (e) {
      this.error = String(e);
    } finally {
      this.loading.delete(key);
      if (this.loading.delete(key + ":again")) this.loadTimeline(key);
    }
  }

  async loadQueue(id: string) {
    const key = id.replace(/^run:/, "");
    try {
      this.queues[key] = await workspaceApi.queue(key);
    } catch {
      delete this.queues[key];
    }
  }

  /// Voert een actie uit en laat een fout zien in plaats van hem in te slikken.
  async act<T>(f: () => Promise<T>): Promise<T | undefined> {
    this.error = null;
    try {
      return await f();
    } catch (e) {
      this.error = String(e);
      return undefined;
    } finally {
      this.refresh();
    }
  }
}

export const workspace = new WorkspaceStore();
