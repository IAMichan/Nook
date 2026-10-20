// Pull requests under Agents › Pull requests (`PullRequestsPanel`, `PullRequestFilter` and `PullRequestDetailView` on
// the Mac): the API, the search and Filters dropdown, and the words the views use.
import { invoke } from "@tauri-apps/api/core";
import type { AccountPullRequests, Ci, PullRequestItem } from "./connectors";

export type DetailState = "open" | "draft" | "merged" | "closed";
export type CheckOutcome = "passing" | "failing" | "pending" | "skipped";
export type MergeMethod = "merge" | "squash" | "rebase";

export interface PullRequestCheck {
  name: string;
  outcome: CheckOutcome;
  detail: string;
  url: string | null;
}

export type PullRequestEvent = {
  id: string;
  author: string;
  /// Markdown, already rewritten from GitHub's HTML by the core; render it with `renderMarkdown`.
  body: string;
  date: string | null;
  url: string | null;
} & (
  | { kind: "comment" }
  | { kind: "review"; state: string }
  | { kind: "lineComment"; path: string; line: number | null }
  | { kind: "commit"; sha: string }
  | { kind: "activity"; event: string; detail: string }
);

export interface PullRequestCommit {
  sha: string;
  message: string;
  author: string;
  date: string | null;
}

export interface PullRequestFile {
  path: string;
  status: string;
  additions: number;
  deletions: number;
  patch: string | null;
  previousPath: string | null;
}

export interface PullRequestDetail {
  repo: string;
  number: number;
  title: string;
  body: string;
  url: string | null;
  author: string;
  state: DetailState;
  baseBranch: string;
  headBranch: string;
  headSha: string;
  additions: number;
  deletions: number;
  changedFiles: number;
  created: string | null;
  updated: string | null;
  mergeable: boolean | null;
  mergeState: string;
  checks: PullRequestCheck[];
  events: PullRequestEvent[];
  commits: PullRequestCommit[];
  files: PullRequestFile[];
  methods: MergeMethod[];
  canPush: boolean | null;
  isOpen: boolean;
  canMerge: boolean;
  checkSummary: Ci;
  mergeNote: string | null;
}

export const pullsApi = {
  detail: (account: string | null, repo: string, number: number) =>
    invoke<PullRequestDetail>("github_pull_request", { account, repo, number }),
  /// Only after the confirmation in the view. Runs the `github_merge_pr` action and writes it to the action log.
  merge: (account: string | null, repo: string, number: number, method: MergeMethod, sha: string) =>
    invoke<string>("github_merge_pull_request", { account, repo, number, method, sha }),
  watchAdd: (text: string) => invoke<string[]>("pull_watch_add", { text }),
  watchRemove: (entry: string) => invoke<string[]>("pull_watch_remove", { entry }),
};

export const itemId = (item: { repo: string; number: number }) => `${item.repo}#${item.number}`;
export const isEmpty = (a: AccountPullRequests) => !a.mine.length && !a.reviews.length && !a.watched.length;

// Search and filters

export type StateFilter = "all" | "open" | "closed" | "merged";
export type ScopeFilter = "all" | "reviews" | "mine" | "watched";
export type DraftFilter = "all" | "drafts" | "ready";
export type StatusFilter = "any" | "failing" | "pending" | "passing";

export interface PullRequestFilter {
  query: string;
  state: StateFilter;
  scope: ScopeFilter;
  /// A login, or null for anyone.
  author: string | null;
  draft: DraftFilter;
  status: StatusFilter;
}

export const defaultFilter = (query = ""): PullRequestFilter => ({ query, state: "open", scope: "all", author: null, draft: "all", status: "any" });

/// How many dropdown choices differ from the default (the search not counted), for the badge on the Filters button.
export function activeCount(f: PullRequestFilter): number {
  return [f.state !== "open", f.scope !== "all", f.author !== null, f.draft !== "all", f.status !== "any"].filter(Boolean).length;
}

const words = (f: PullRequestFilter) => f.query.toLowerCase().split(/\s+/).filter(Boolean);

export const isActive = (f: PullRequestFilter) => words(f).length > 0 || activeCount(f) > 0;

/// Every word of the search must appear; "@ada" matches the author, "#12" (or a bare 12) the number.
export function matches(f: PullRequestFilter, item: PullRequestItem): boolean {
  if (f.state !== "all" && item.state !== f.state) return false;
  if (f.author !== null && item.author.toLowerCase() !== f.author.toLowerCase()) return false;
  if (f.draft === "drafts" && !item.draft) return false;
  if (f.draft === "ready" && item.draft) return false;
  if (f.status !== "any" && item.ci !== f.status) return false;
  const text = `${item.repo}#${item.number} ${item.title} @${item.author}`.toLowerCase();
  return words(f).every((word) => {
    // A number is the pull request's number, never part of another one ("#123").
    const digits = word.startsWith("#") ? word.slice(1) : word;
    if (/^\d+$/.test(digits)) return item.number === Number(digits) || (!word.startsWith("#") && text.includes(word));
    return text.includes(word);
  });
}

/// The account with only the pull requests that match. An error stays, so a failing account never disappears.
export function apply(f: PullRequestFilter, account: AccountPullRequests): AccountPullRequests {
  const keep = (scope: ScopeFilter, items: PullRequestItem[]) => (f.scope === "all" || f.scope === scope ? items.filter((i) => matches(f, i)) : []);
  return { ...account, reviews: keep("reviews", account.reviews), mine: keep("mine", account.mine), watched: keep("watched", account.watched) };
}

/// Every author in the lists, for the Author choice: most pull requests first, then by name.
export function authors(accounts: AccountPullRequests[]): string[] {
  const counts = new Map<string, number>();
  for (const a of accounts) {
    for (const item of [...a.mine, ...a.reviews, ...a.watched]) {
      if (item.author) counts.set(item.author, (counts.get(item.author) ?? 0) + 1);
    }
  }
  return [...counts.entries()]
    .sort((x, y) => y[1] - x[1] || x[0].toLowerCase().localeCompare(y[0].toLowerCase()))
    .map(([login]) => login);
}

/// Watched entries that no account could search, while at least one account could be read.
export function unreadable(accounts: AccountPullRequests[], watching: string[]): string[] {
  const readers = accounts.filter((a) => !a.error);
  if (!readers.length) return [];
  return watching.filter((entry) => readers.every((a) => a.unreadable.includes(entry)));
}

// Words (the Dutch strings of the Mac app)

export const stateNames: Record<StateFilter, string> = { all: "Alle", open: "Open", closed: "Gesloten", merged: "Gemerged" };
export const scopeNames: Record<ScopeFilter, string> = { all: "Alles", reviews: "Te reviewen", mine: "Van jou", watched: "Gevolgd" };
export const draftNames: Record<DraftFilter, string> = { all: "Alle", drafts: "Alleen concepten", ready: "Klaar voor review" };
export const statusNames: Record<StatusFilter, string> = { any: "Elke status", failing: "CI faalt", pending: "CI loopt", passing: "CI geslaagd" };
export const detailStateNames: Record<DetailState, string> = { open: "Open", draft: "Concept", merged: "Samengevoegd", closed: "Gesloten" };
export const methodNames: Record<MergeMethod, string> = {
  merge: "Met merge-commit",
  squash: "Squashen tot één commit",
  rebase: "Rebasen op basisbranch",
};

const notes: Record<string, string> = {
  ready: "Klaar om te mergen.",
  merged: "Deze pull request is samengevoegd.",
  closed: "Deze pull request is gesloten.",
  draft: "Concept: zet hem op GitHub klaar voor review voordat je merget.",
  noAccess: "Dit account mag in deze repository niet mergen.",
  conflict: "Er is een merge-conflict met de basisbranch.",
  blocked: "Branchbeveiliging houdt de merge tegen (reviews of verplichte checks). GitHub laat hem alleen door als je dat mag omzeilen.",
  behind: "De branch loopt achter op zijn basis en moet eerst worden bijgewerkt.",
  unstable: "Sommige checks falen.",
  checking: "GitHub controleert nog of hij kan worden gemerged.",
};

export const noteText = (note: string | null) => notes[note ?? "ready"] ?? notes.ready;

/// The sentence after "@actor" for a timeline event; `%` is what it is about.
const activities: Record<string, string> = {
  labeled: "voegde het label % toe",
  unlabeled: "haalde het label % weg",
  assigned: "wees % toe",
  unassigned: "haalde % eraf",
  review_requested: "vroeg % om een review",
  review_request_removed: "trok het reviewverzoek aan % in",
  renamed: "veranderde de titel in %",
  head_ref_force_pushed: "deed een force-push op de branch",
  head_ref_deleted: "verwijderde de branch",
  head_ref_restored: "herstelde de branch",
  base_ref_changed: "veranderde de basisbranch",
  merged: "mergede commit %",
  closed: "sloot deze pull request",
  reopened: "heropende deze pull request",
  ready_for_review: "zette hem klaar voor review",
  convert_to_draft: "maakte er een concept van",
  "cross-referenced": "noemde dit in %",
  referenced: "verwees hiernaar in commit %",
  milestoned: "voegde dit toe aan mijlpaal %",
  demilestoned: "haalde dit uit mijlpaal %",
  auto_merge_enabled: "zette automatisch mergen aan",
  auto_merge_disabled: "zette automatisch mergen uit",
  review_dismissed: "trok een review in",
};

export function activitySentence(event: string, detail: string): string {
  return (activities[event] ?? event).replace("%", detail);
}

/// The label after "@author" on a review or comment card, and its tone.
export function eventLabel(e: PullRequestEvent): { text: string; tone: "" | "good" | "bad" } {
  switch (e.kind) {
    case "comment":
      return { text: "reageerde", tone: "" };
    case "lineComment":
      return { text: `reageerde op ${e.line !== null ? `${e.path}:${e.line}` : e.path}`, tone: "" };
    case "review":
      if (e.state === "APPROVED") return { text: "keurde goed", tone: "good" };
      if (e.state === "CHANGES_REQUESTED") return { text: "vroeg om wijzigingen", tone: "bad" };
      if (e.state === "DISMISSED") return { text: "review ingetrokken", tone: "" };
      return { text: "gaf een review", tone: "" };
    default:
      return { text: "", tone: "" };
  }
}

/// The method shown in the merge bar: the one chosen before when the repository allows it, else its first.
export function chosenMethod(saved: string | null, allowed: MergeMethod[]): MergeMethod {
  const wanted = (["merge", "squash", "rebase"] as MergeMethod[]).find((m) => m === saved) ?? "merge";
  return allowed.includes(wanted) || !allowed.length ? wanted : allowed[0];
}

/// A unified diff as lines with their kind, for drawing.
export function diffLines(patch: string): { kind: "add" | "remove" | "hunk" | "context"; text: string }[] {
  return patch.split("\n").map((text) => ({
    kind: text.startsWith("@@") ? "hunk" : text.startsWith("+") ? "add" : text.startsWith("-") ? "remove" : "context",
    text,
  }));
}
