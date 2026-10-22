// The pull request list kept between visits (`PullRequestStore` on the Mac): the last list shows at once, also after a
// restart, and refreshes in the background when it is older than half a minute. A failed refresh keeps an account's rows.
import { untrack } from "svelte";
import { connectorsApi, type AccountPullRequests } from "./connectors";

const CACHE = "pulls.list";
const STALE_AFTER = 30_000;

function saved(): AccountPullRequests[] {
  try {
    const list = JSON.parse(localStorage.getItem(CACHE) ?? "[]") as AccountPullRequests[];
    // A list saved before watching existed has no watched rows.
    return Array.isArray(list) ? list.map((a) => ({ ...a, watched: a.watched ?? [], unreadable: a.unreadable ?? [] })) : [];
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
      this.accounts = fresh.accounts.map((account) => {
        const old = account.error ? this.accounts.find((a) => a.id === account.id) : undefined;
        return old ? { ...old, error: account.error, errorKind: account.errorKind } : account;
      });
      this.fetchedAt = Date.now();
      // GitHub was disconnected: no old rows from an account Nook can no longer read.
      save(this.accounts);
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
}

export const pullRequests = new PullRequestStore();
