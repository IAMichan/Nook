// Pull requests under Agents › Pull requests (`PullRequestsPanel`, `PullRequestFilter` and `PullRequestDetailView` on
// the Mac): the API, the search and Filters dropdown, and the words the views use.
import { invoke } from "@tauri-apps/api/core";
import type { AccountPullRequests, Ci, PullRequestItem } from "./connectors";

export type DetailState = "open" | "draft" | "merged" | "closed";
export type CheckOutcome = "passing" | "failing" | "pending" | "skipped";
export type ReviewEvent = "APPROVE" | "REQUEST_CHANGES" | "COMMENT";
export type MergeMethod = "merge" | "squash" | "rebase";

export interface PullRequestCheck {
  name: string;
  outcome: CheckOutcome;
  detail: string;
  url: string | null;
}

/// One step of a GitHub Actions job.
export interface CiStep {
  number: number;
  name: string;
  outcome: CheckOutcome;
}

/// What a check shows when you open it in Nook (`CILog` on the Mac): its job's steps and the end of its log.
export interface CiLog {
  steps: CiStep[];
  /// Null while GitHub has no log yet (the job still runs).
  text: string | null;
  omittedLines: number;
}

export type CiLineKind = "plain" | "group" | "command" | "error" | "warning" | "notice";
export interface CiLine {
  kind: CiLineKind;
  text: string;
}

const MARKERS: [string, CiLineKind][] = [
  ["##[group]", "group"],
  ["##[command]", "command"],
  ["##[error]", "error"],
  ["##[warning]", "warning"],
  ["##[notice]", "notice"],
];

/// The cleaned log as lines with a kind (`CILogParser.lines` on the Mac): GitHub's `##[…]` markers become the kind and
/// leave the text, `##[endgroup]` and `##[debug]` are dropped, and a plain line saying "error:", "warning:" or that the
/// build failed counts too.
export function ciLines(text: string): CiLine[] {
  const lines: CiLine[] = [];
  for (const line of text.split("\n")) {
    const marker = MARKERS.find(([prefix]) => line.startsWith(prefix));
    if (marker) {
      lines.push({ kind: marker[1], text: line.slice(marker[0].length) });
      continue;
    }
    if (line.startsWith("##[endgroup]") || line.startsWith("##[debug]")) continue;
    const lower = line.toLowerCase();
    const kind: CiLineKind =
      lower.includes("error:") || lower.includes("build failed") || lower.includes("test failed") || lower.startsWith("fatal:")
        ? "error"
        : lower.includes("warning:")
          ? "warning"
          : "plain";
    lines.push({ kind, text: line });
  }
  return lines;
}

/// Only what went wrong: the error and warning lines, each group's name before its first one.
export function ciProblems(lines: CiLine[]): CiLine[] {
  const result: CiLine[] = [];
  let group: CiLine | null = null;
  for (const line of lines) {
    if (line.kind === "group") group = line;
    else if (line.kind === "error" || line.kind === "warning") {
      if (group) {
        result.push(group);
        group = null;
      }
      result.push(line);
    }
  }
  return result;
}

/// The job id of a GitHub Actions check ("…/actions/runs/123/job/456" → 456); null for a check from another app, which
/// has no log for Nook to read. The same rule as `job_id` in the core.
export function jobId(url: string | null): number | null {
  if (!url) return null;
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return null;
  }
  if (!parsed.hostname.endsWith("github.com")) return null;
  const parts = parsed.pathname.split("/").filter(Boolean);
  const index = parts.indexOf("job");
  if (index < 0 || !parts.includes("actions")) return null;
  const id = Number(parts[index + 1]);
  return Number.isInteger(id) && id > 0 ? id : null;
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
  /// Your permission in the repository: ADMIN, MAINTAIN, WRITE, TRIAGE or READ.
  permission: string | null;
  /// Whether you may merge although branch protection blocks it.
  canBypass: boolean | null;
  autoMerge: boolean;
  isOpen: boolean;
  canMerge: boolean;
  checkSummary: Ci;
  mergeNote: string | null;
}

export const pullsApi = {
  detail: (account: string | null, repo: string, number: number) =>
    invoke<PullRequestDetail>("github_pull_request", { account, repo, number }),
  ciLog: (account: string | null, repo: string, job: number) => invoke<CiLog>("github_ci_log", { account, repo, job }),
  /// Only after the confirmation in the view. Runs the `github_merge_pr` action and writes it to the action log.
  merge: (account: string | null, repo: string, number: number, method: MergeMethod, sha: string) =>
    invoke<string>("github_merge_pull_request", { account, repo, number, method, sha }),
  /// Approves, asks for changes on or comments on a pull request (`APPROVE`, `REQUEST_CHANGES`, `COMMENT`); only after a click.
  review: (account: string | null, repo: string, number: number, event: ReviewEvent, body: string) =>
    invoke<string>("github_review_pull_request", { account, repo, number, event, body }),
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
  noAccess: "Je hebt geen schrijfrechten in deze repository, dus je kunt hem niet zelf mergen. Wacht tot een maintainer hem merget; Nook houdt hem bij.",
  auto: "Automatisch mergen staat aan: hij wordt gemerged zodra alle vereiste reviews en checks er zijn.",
  conflict: "Er is een merge-conflict met de basisbranch.",
  blocked: "Branchbeveiliging houdt de merge tegen: er ontbreken vereiste reviews of checks. Je mag dat niet omzeilen, dus wacht tot het in orde is.",
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

// The GitHub dashboard in Chats: every open pull request sorted by what you have to do about it.

export type Lane = "review" | "fix" | "ready" | "waiting" | "draft" | "merged";
export type Reason = "reviewRequested" | "failing" | "changes" | "conflict" | "approved" | "passing" | "pending" | "needsReview" | "draft" | "merged";

export interface Triaged {
  account: string;
  item: PullRequestItem;
  lane: Lane;
  reasons: Reason[];
}

/// The order the lanes are shown in: what needs you first, what only waits last.
export const LANES: Lane[] = ["review", "fix", "ready", "waiting", "draft", "merged"];

/// A pull request of yours: broken (CI, requested changes, a conflict), ready to merge, a draft, or waiting on others.
export function laneOfMine(item: PullRequestItem): { lane: Lane; reasons: Reason[] } {
  if (item.state === "merged") return { lane: "merged", reasons: ["merged"] };
  if (item.draft) return { lane: "draft", reasons: ["draft"] };
  const broken: Reason[] = [];
  if (item.ci === "failing") broken.push("failing");
  if (item.review === "changesRequested") broken.push("changes");
  if (item.conflicting) broken.push("conflict");
  if (broken.length) return { lane: "fix", reasons: broken };
  if (item.ci !== "pending" && (item.review === "approved" || item.review === "none")) {
    return { lane: "ready", reasons: [item.review === "approved" ? "approved" : "passing"] };
  }
  return { lane: "waiting", reasons: [item.ci === "pending" ? "pending" : "needsReview"] };
}

/// Open pull requests waiting for your review and your own, plus your last few merged ones; each pull request once.
export function triage(accounts: AccountPullRequests[], mergedLimit = 5): Triaged[] {
  const seen = new Set<string>();
  const result: Triaged[] = [];
  const add = (account: string, item: PullRequestItem, lane: Lane, reasons: Reason[]) => {
    if (seen.has(itemId(item))) return;
    seen.add(itemId(item));
    result.push({ account, item, lane, reasons });
  };
  for (const a of accounts) {
    for (const item of a.reviews) if (item.state === "open") add(a.id, item, "review", ["reviewRequested"]);
  }
  for (const a of accounts) {
    for (const item of a.mine) {
      if (item.state === "closed") continue;
      if (item.state === "merged") continue;
      const { lane, reasons } = laneOfMine(item);
      add(a.id, item, lane, reasons);
    }
  }
  const merged = accounts
    .flatMap((a) => a.mine.filter((i) => i.state === "merged").map((item) => ({ account: a.id, item })))
    .sort((x, y) => (y.item.updated ?? "").localeCompare(x.item.updated ?? ""))
    .slice(0, mergedLimit);
  for (const { account, item } of merged) add(account, item, "merged", ["merged"]);
  const rank = (t: Triaged) => LANES.indexOf(t.lane);
  return result.sort((x, y) => rank(x) - rank(y) || (y.item.updated ?? "").localeCompare(x.item.updated ?? ""));
}

/// How many pull requests are in each lane, for the tiles that filter the dashboard.
export function laneCounts(items: Triaged[]): Record<Lane, number> {
  const counts: Record<Lane, number> = { review: 0, fix: 0, ready: 0, waiting: 0, draft: 0, merged: 0 };
  for (const t of items) counts[t.lane]++;
  return counts;
}

/// Whether a triaged pull request or issue matches the dashboard's search words (repo, title, "#12", "@author").
export function matchesQuery(query: string, parts: { repo: string; number: number; title: string; author: string }): boolean {
  const text = `${parts.repo}#${parts.number} ${parts.title} @${parts.author}`.toLowerCase();
  return query
    .toLowerCase()
    .split(/\s+/)
    .filter(Boolean)
    .every((w) => text.includes(w.startsWith("#") ? `#${w.slice(1)}` : w));
}

/// The size of a change as a short label: "+120 −8".
export const sizeLabel = (item: { additions: number; deletions: number }) => (item.additions || item.deletions ? `+${item.additions} −${item.deletions}` : "");
