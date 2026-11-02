// The pull request list kept between visits (`PullRequestStore` on the Mac): the last list shows at once, also after a
// restart, and refreshes in the background when it is older than half a minute. A failed refresh keeps an account's rows.
// With its page closed the list is read again now and then (`followInBackground`), and after every read the pages you
// are most likely to open are read ahead (`pullDetails`), so opening one shows it at once.
import { untrack } from "svelte";
import { connectorsApi, type AccountPullRequests, type PullRequestItem } from "./connectors";
import { detailKey, listDue, pullsApi, slowdown, warmPicks, BACKGROUND_EVERY, type Pace, type PullRequestDetail } from "./pulls";
import { services } from "./services";

const CACHE = "pulls.list";
const STALE_AFTER = 30_000;

// A list saved before reviews, sizes and issues existed lacks those fields.
const row = (i: PullRequestItem): PullRequestItem => ({ ...i, review: i.review ?? "none", comments: i.comments ?? 0, additions: i.additions ?? 0, deletions: i.deletions ?? 0, conflicting: i.conflicting ?? false });

/// Fills in what an older list or an older backend does not send, so a view never meets a missing field.
function normalize(a: AccountPullRequests): AccountPullRequests {
  return {
    ...a,
    mine: (a.mine ?? []).map(row),
    reviews: (a.reviews ?? []).map(row),
    watched: (a.watched ?? []).map(row),
    issues: a.issues ?? [],
    unreadable: a.unreadable ?? [],
  };
}

function saved(): AccountPullRequests[] {
  try {
    const list = JSON.parse(localStorage.getItem(CACHE) ?? "[]") as AccountPullRequests[];
    return Array.isArray(list) ? list.map(normalize) : [];
  } catch {
    return [];
  }
}

function save(accounts: AccountPullRequests[]) {
  try {
    if (accounts.length) localStorage.setItem(CACHE, JSON.stringify(accounts.map((a) => ({ ...a, error: null, errorKind: null }))));
    else localStorage.removeItem(CACHE);
  } catch {
    // Only a convenience: the list loads again on the next visit.
  }
}

class PullRequestStore {
  accounts = $state<AccountPullRequests[]>(saved());
  loading = $state(false);
  loaded = $state(false);
  available = $state(true);
  error = $state<string | null>(null);
  private fetchedAt = 0;

  constructor() {
    this.loaded = this.accounts.length > 0;
  }

  /// Refreshes when stale (or always with `force`); returns at once while a refresh is already running.
  /// Read without tracking: an effect that calls `refresh()` must not run again each time `loading` flips, or a failing
  /// fetch (which leaves `fetchedAt` at 0) would retry in a tight loop.
  async refresh(force = false) {
    if (untrack(() => this.loading) || (!force && Date.now() - this.fetchedAt < STALE_AFTER)) return;
    this.loading = true;
    try {
      const fresh = await connectorsApi.githubPullRequests();
      this.available = fresh.available;
      this.error = null;
      // An account that failed this time keeps its last rows, with the error shown.
      this.accounts = fresh.accounts.map(normalize).map((account) => {
        const old = account.error ? this.accounts.find((a) => a.id === account.id) : undefined;
        return old ? { ...old, error: account.error, errorKind: account.errorKind } : account;
      });
      this.fetchedAt = Date.now();
      // GitHub was disconnected: no old rows from an account Nook can no longer read.
      save(this.accounts);
      // The pages you are most likely to open next are read ahead now, so they show at once.
      void pullDetails.warm(this.accounts);
    } catch (e) {
      this.error = String(e);
    } finally {
      this.loading = false;
      this.loaded = true;
    }
  }

  /// Something changed (a merge, the watch list): the next look refreshes.
  markStale() {
    this.fetchedAt = 0;
  }

  /// Reads the list now and then while its page is closed, from when the main window opens; returns the stop. Each
  /// wait is the whole interval (stretched by the energy plan), so it costs one wake-up and one read every ten minutes
  /// at most. A list its page read meanwhile counts as read.
  followInBackground(): () => void {
    let stopped = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const tick = async () => {
      const pace = await currentPace();
      if (stopped) return;
      if (listDue(this.fetchedAt, Date.now(), pace)) await this.refresh();
      if (!stopped) timer = setTimeout(tick, BACKGROUND_EVERY * slowdown(pace));
    };
    timer = setTimeout(tick, BACKGROUND_EVERY);
    return () => {
      stopped = true;
      clearTimeout(timer);
    };
  }
}

/// The energy plan's pace; full when it cannot be read.
async function currentPace(): Promise<Pace> {
  try {
    return (await services.energyStatus()).plan.pace;
  } catch {
    return "full";
  }
}

/// Every pull request page read while Nook runs (`PullRequestDetailModel`'s cache on the Mac): opening one again shows
/// it at once and refreshes underneath. A read already under way (ahead of you, or by the page) is shared.
class PullRequestDetails {
  private cache = new Map<string, { detail: PullRequestDetail; at: number }>();
  private reading = new Map<string, Promise<PullRequestDetail>>();
  private warming = false;
  /// Enough for a morning of reviews; the oldest go first.
  private static LIMIT = 40;

  get(account: string, repo: string, number: number) {
    return this.cache.get(detailKey(account, repo, number));
  }

  remember(account: string, detail: PullRequestDetail) {
    const key = detailKey(account, detail.repo, detail.number);
    this.cache.delete(key);
    this.cache.set(key, { detail, at: Date.now() });
    while (this.cache.size > PullRequestDetails.LIMIT) {
      const oldest = this.cache.keys().next().value;
      if (oldest === undefined) break;
      this.cache.delete(oldest);
    }
  }

  /// Reads the pull request and keeps it. With `share`, a read already running for it is waited for instead.
  read(account: string, repo: string, number: number, share = false): Promise<PullRequestDetail> {
    const key = detailKey(account, repo, number);
    const running = this.reading.get(key);
    if (share && running) return running;
    const started = Date.now();
    const read = pullsApi
      .detail(account, repo, number)
      .then((detail) => {
        // A newer read (an open page's) may have landed meanwhile; it stays.
        if ((this.cache.get(key)?.at ?? 0) < started) this.remember(account, detail);
        return detail;
      })
      .finally(() => {
        if (this.reading.get(key) === read) this.reading.delete(key);
      });
    this.reading.set(key, read);
    return read;
  }

  /// Reads ahead what `warmPicks` chooses, one at a time so it never competes with what you are doing; returns at once
  /// while a pass runs. A failed read is left for the page to try.
  async warm(accounts: AccountPullRequests[]) {
    if (this.warming) return;
    this.warming = true;
    try {
      const pace = await currentPace();
      const seen = (key: string) => {
        const kept = this.cache.get(key);
        return kept ? { updated: kept.detail.updated, at: kept.at } : undefined;
      };
      for (const { account, item } of warmPicks(accounts, seen, Date.now(), pace)) {
        await this.read(account, item.repo, item.number, true).catch(() => {});
      }
    } finally {
      this.warming = false;
    }
  }
}

export const pullDetails = new PullRequestDetails();

export const pullRequests = new PullRequestStore();
