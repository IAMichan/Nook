// The inbox service (Svelte 5 runes): features register a provider, Home reads `ranked`. Each provider loads on its
// own, so a slow one never holds up the rest, and the last list is cached so Home shows it before anything answers.
import { untrack } from "svelte";
import { nook } from "./state.svelte";
import { toast } from "./toast.svelte";
import { pruneDismissed, rank, type InboxItem, type Prioritizer, type Ranked, type Target } from "./inbox";

export interface InboxProvider {
  id: string;
  /// The provider's current items. Throwing keeps its last items.
  load(): Promise<InboxItem[]>;
  /// Runs one of its items' actions; a `Target` tells Home where to go next.
  act?(item: InboxItem, action: string): Promise<Target | void> | Target | void;
  /// Calls `changed` when its data changes; returns how to stop.
  watch?(changed: () => void): () => void;
}

const CACHE = "inbox.cache";
const REFRESH = 60_000;

function cached(): Record<string, InboxItem[]> {
  try {
    const value = JSON.parse(localStorage.getItem(CACHE) ?? "{}");
    return value && typeof value === "object" && !Array.isArray(value) ? value : {};
  } catch {
    return {};
  }
}

class InboxService {
  /// Items per provider.
  private byProvider = $state<Record<string, InboxItem[]>>(cached());
  /// Items a feature pushed itself (`addItem`), for events that have no list to load.
  private pushed = $state<InboxItem[]>([]);
  private providers = new Map<string, InboxProvider>();
  private stops: (() => void)[] = [];
  private pendingLoads = $state(0);
  private timer: ReturnType<typeof setInterval> | null = null;
  private order: Prioritizer | undefined;
  /// Bumped when the ranking itself changes (a new prioritizer), since `order` is not reactive.
  private orderVersion = $state(0);

  /// True until every provider answered once and nothing was cached: Home shows a calm placeholder meanwhile.
  loading = $derived(this.pendingLoads > 0 && Object.keys(this.byProvider).length === 0);
  items = $derived([...Object.values(this.byProvider).flat(), ...this.pushed]);
  dismissed = $derived(nook.settings?.inboxDismissed ?? {});
  ranked: Ranked = $derived.by(() => (this.orderVersion, rank(this.items, this.dismissed, Date.now(), this.order)));

  register(provider: InboxProvider) {
    if (this.providers.has(provider.id)) return;
    this.providers.set(provider.id, provider);
    if (this.timer) this.attach(provider);
  }

  /// Starts loading and watching every provider. Home calls it; it is cheap to call again.
  /// Untracked: an effect that starts the inbox must not rerun on every list it loads.
  start() {
    if (this.timer) return;
    untrack(() => {
      // A cached list from a provider that no longer exists would never refresh.
      this.byProvider = Object.fromEntries(Object.entries(this.byProvider).filter(([id]) => this.providers.has(id)));
      for (const p of this.providers.values()) this.attach(p);
    });
    this.timer = setInterval(() => this.refresh(), REFRESH);
  }

  stop() {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    for (const stop of this.stops.splice(0)) stop();
  }

  refresh() {
    for (const p of this.providers.values()) this.load(p);
  }

  /// A one-off item from anywhere in Nook (`provider` handles its actions, if registered).
  addItem(item: InboxItem) {
    this.pushed = [...this.pushed.filter((i) => i.id !== item.id), item];
  }

  async dismiss(id: string) {
    this.pushed = this.pushed.filter((i) => i.id !== id);
    if (!nook.settings) return;
    const now = Date.now();
    await nook.saveSettings((s) => ({ inboxDismissed: { ...pruneDismissed(s.inboxDismissed ?? {}, now), [id]: new Date(now).toISOString() } }));
  }

  /// Read: it stays answered, so it leaves the inbox like a dismissal.
  markAsRead(id: string) {
    return this.dismiss(id);
  }

  getImportantItems(): InboxItem[] {
    return this.ranked.shown;
  }

  /// For a later AI ranking: same items in, a new order out.
  setPrioritizer(order: Prioritizer | undefined) {
    this.order = order;
    this.orderVersion++;
  }

  async act(item: InboxItem, action: string): Promise<Target | void> {
    const provider = this.providers.get(item.provider);
    try {
      const target = await provider?.act?.(item, action);
      this.load(provider);
      return target;
    } catch (e) {
      toast.error(item.title, e);
    }
  }

  private attach(p: InboxProvider) {
    this.load(p);
    if (p.watch) this.stops.push(p.watch(() => this.load(p)));
  }

  private async load(p: InboxProvider | undefined) {
    if (!p) return;
    this.pendingLoads++;
    try {
      this.byProvider = { ...this.byProvider, [p.id]: await p.load() };
      this.save();
    } catch {
      // The provider keeps what it showed; the next refresh tries again.
    } finally {
      this.pendingLoads--;
    }
  }

  private save() {
    try {
      localStorage.setItem(CACHE, JSON.stringify(this.byProvider));
    } catch {
      // Only a head start for the next visit.
    }
  }
}

export const inbox = new InboxService();
