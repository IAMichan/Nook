// Pull requests under Agents › Pull requests (`PullRequestsPanel`, `PullRequestFilter` and `PullRequestDetailView` on
// the Mac): the API, the search and Filters dropdown, and the words the views use.
import { invoke } from "@tauri-apps/api/core";
import type { AccountPullRequests, Ci, PullRequestItem } from "./connectors";
import { tr } from "./i18n.svelte";

export type DetailState = "open" | "draft" | "merged" | "closed";
export type CheckOutcome = "passing" | "failing" | "pending" | "skipped";
export type ReviewEvent = "APPROVE" | "REQUEST_CHANGES" | "COMMENT";
export type MergeMethod = "merge" | "squash" | "rebase";

export interface PullRequestCheck {
  name: string;
  outcome: CheckOutcome;
  detail: string;
  url: string | null;
  /// A check run (GitHub's status words in `detail`) rather than a commit status (its own sentence).
  checkRun: boolean;
  /// Runs right now; a pending check that has not started yet is queued.
  running: boolean;
  started: string | null;
  finished: string | null;
}

/// One step of a GitHub Actions job.
export interface CiStep {
  number: number;
  name: string;
  outcome: CheckOutcome;
  started: string | null;
  finished: string | null;
  /// Runs right now (a pending step that has not started yet waits).
  running: boolean;
}

/// What a check shows when you open it in Nook (`CILog` on the Mac): its job's steps and the end of its log.
export interface CiLog {
  steps: CiStep[];
  /// Null while GitHub has no log yet (the job still runs).
  text: string | null;
  omittedLines: number;
  /// When the job started and finished, for its clock; null while it waits or runs.
  started: string | null;
  finished: string | null;
}

/// A duration as a clock that reads the same in every language: "0:42", "3:12", "1:04:05" (`CILogParser.clock` on the Mac).
export function ciClock(seconds: number): string {
  const total = Math.max(0, Math.floor(seconds));
  const h = Math.floor(total / 3600), m = Math.floor(total / 60) % 60, s = total % 60;
  const pad = (n: number) => String(n).padStart(2, "0");
  return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${m}:${pad(s)}`;
}

/// How long something ran in seconds: until it finished, or until `now` while it still runs. Null before it started.
export function ciElapsed(started: string | null, finished: string | null, now: number = Date.now()): number | null {
  if (!started) return null;
  return ((finished ? Date.parse(finished) : now) - Date.parse(started)) / 1000;
}

/// The line under a check's name in words, with its clock: "Bezig · 3:12", "Mislukt na 4:05", "In de wachtrij"
/// (`CICheckStatusText` on the Mac). A commit status from another app keeps its own sentence.
export function ciStatusLine(check: PullRequestCheck, now: number = Date.now(), extra: string | null = null): string {
  if (!check.checkRun) return check.detail.replaceAll("_", " ");
  const seconds = ciElapsed(check.started, check.finished, now);
  const clock = seconds === null ? null : ciClock(seconds);
  switch (check.outcome) {
    case "pending":
      if (!check.running) return tr("In de wachtrij", "Queued");
      return [tr("Bezig", "Running"), clock, extra].filter(Boolean).join(" · ");
    case "skipped":
      return tr("Overgeslagen", "Skipped");
    default:
      if (check.detail === "cancelled") return clock ? tr("Geannuleerd na {time}", "Cancelled after {time}", { time: clock }) : tr("Geannuleerd", "Cancelled");
      if (check.detail === "timed_out") return clock ? tr("Time-out na {time}", "Timed out after {time}", { time: clock }) : tr("Time-out", "Timed out");
      if (check.outcome === "passing") return clock ? tr("Geslaagd in {time}", "Succeeded in {time}", { time: clock }) : tr("Geslaagd", "Succeeded");
      return clock ? tr("Mislukt na {time}", "Failed after {time}", { time: clock }) : tr("Mislukt", "Failed");
  }
}

/// Watched entries that no account could search, while at least one account could be read.
export function unreadable(accounts: AccountPullRequests[], watching: string[]): string[] {
  const readers = accounts.filter((a) => !a.error);
  if (!readers.length) return [];
  return watching.filter((entry) => readers.every((a) => a.unreadable.includes(entry)));
}

// Words (the strings of the Mac app). The name tables read through getters, so each read is in the current language.

export const stateNames: Record<StateFilter, string> = {
  get all() { return tr("Alle", "All"); },
  get open() { return tr("Open", "Open"); },
  get closed() { return tr("Gesloten", "Closed"); },
  get merged() { return tr("Gemerged", "Merged"); },
};
export const scopeNames: Record<ScopeFilter, string> = {
  get all() { return tr("Alles", "Everything"); },
  get reviews() { return tr("Te reviewen", "To review"); },
  get mine() { return tr("Van jou", "Yours"); },
  get watched() { return tr("Gevolgd", "Watched"); },
};
export const draftNames: Record<DraftFilter, string> = {
  get all() { return tr("Alle", "All"); },
  get drafts() { return tr("Alleen concepten", "Drafts only"); },
  get ready() { return tr("Klaar voor review", "Ready for review"); },
};
export const statusNames: Record<StatusFilter, string> = {
  get any() { return tr("Elke status", "Any status"); },
  get failing() { return tr("CI faalt", "CI failing"); },
  get pending() { return tr("CI loopt", "CI running"); },
  get passing() { return tr("CI geslaagd", "CI passed"); },
};
export const detailStateNames: Record<DetailState, string> = {
  get open() { return tr("Open", "Open"); },
  get draft() { return tr("Concept", "Draft"); },
  get merged() { return tr("Samengevoegd", "Merged"); },
  get closed() { return tr("Gesloten", "Closed"); },
};
export const methodNames: Record<MergeMethod, string> = {
  get merge() { return tr("Met merge-commit", "Create a merge commit"); },
  get squash() { return tr("Squashen tot één commit", "Squash into one commit"); },
  get rebase() { return tr("Rebasen op basisbranch", "Rebase onto the base branch"); },
};

/// The sentence under the merge bar for GitHub's merge state.
export function noteText(note: string | null): string {
  switch (note ?? "ready") {
    case "merged": return tr("Deze pull request is samengevoegd.", "This pull request was merged.");
    case "closed": return tr("Deze pull request is gesloten.", "This pull request is closed.");
    case "draft": return tr("Concept: zet hem op GitHub klaar voor review voordat je merget.", "Draft: mark it ready for review on GitHub before you merge.");
    case "noAccess": return tr(
      "Je hebt geen schrijfrechten in deze repository, dus je kunt hem niet zelf mergen. Wacht tot een maintainer hem merget; Nook houdt hem bij.",
      "You don't have write access to this repository, so you can't merge it yourself. Wait for a maintainer to merge it; Nook keeps track of it.",
    );
    case "auto": return tr(
      "Automatisch mergen staat aan: hij wordt gemerged zodra alle vereiste reviews en checks er zijn.",
      "Auto-merge is on: it merges as soon as all required reviews and checks are in.",
    );
    case "conflict": return tr("Er is een merge-conflict met de basisbranch.", "There is a merge conflict with the base branch.");
    case "blocked": return tr(
      "Branchbeveiliging houdt de merge tegen: er ontbreken vereiste reviews of checks. Je mag dat niet omzeilen, dus wacht tot het in orde is.",
      "Branch protection blocks the merge: required reviews or checks are missing. You can't bypass that, so wait until it's in order.",
    );
    case "behind": return tr("De branch loopt achter op zijn basis en moet eerst worden bijgewerkt.", "The branch is behind its base and must be updated first.");
    case "unstable": return tr("Sommige checks falen.", "Some checks are failing.");
    case "checking": return tr("GitHub controleert nog of hij kan worden gemerged.", "GitHub is still checking whether it can be merged.");
    default: return tr("Klaar om te mergen.", "Ready to merge.");
  }
}

/// The sentence after "@actor" for a timeline event; `detail` is what it is about. An event Nook does not know keeps
/// GitHub's name.
export function activitySentence(event: string, detail: string): string {
  const x = { x: detail };
  switch (event) {
    case "labeled": return tr("voegde het label {x} toe", "added the label {x}", x);
    case "unlabeled": return tr("haalde het label {x} weg", "removed the label {x}", x);
    case "assigned": return tr("wees {x} toe", "assigned {x}", x);
    case "unassigned": return tr("haalde {x} eraf", "unassigned {x}", x);
    case "review_requested": return tr("vroeg {x} om een review", "requested a review from {x}", x);
    case "review_request_removed": return tr("trok het reviewverzoek aan {x} in", "removed the review request for {x}", x);
    case "renamed": return tr("veranderde de titel in {x}", "changed the title to {x}", x);
    case "head_ref_force_pushed": return tr("deed een force-push op de branch", "force-pushed the branch");
    case "head_ref_deleted": return tr("verwijderde de branch", "deleted the branch");
    case "head_ref_restored": return tr("herstelde de branch", "restored the branch");
    case "base_ref_changed": return tr("veranderde de basisbranch", "changed the base branch");
    case "merged": return tr("mergede commit {x}", "merged commit {x}", x);
    case "closed": return tr("sloot deze pull request", "closed this pull request");
    case "reopened": return tr("heropende deze pull request", "reopened this pull request");
    case "ready_for_review": return tr("zette hem klaar voor review", "marked it ready for review");
    case "convert_to_draft": return tr("maakte er een concept van", "converted it to a draft");
    case "cross-referenced": return tr("noemde dit in {x}", "mentioned this in {x}", x);
    case "referenced": return tr("verwees hiernaar in commit {x}", "referenced this in commit {x}", x);
    case "milestoned": return tr("voegde dit toe aan mijlpaal {x}", "added this to milestone {x}", x);
    case "demilestoned": return tr("haalde dit uit mijlpaal {x}", "removed this from milestone {x}", x);
    case "auto_merge_enabled": return tr("zette automatisch mergen aan", "enabled auto-merge");
    case "auto_merge_disabled": return tr("zette automatisch mergen uit", "disabled auto-merge");
    case "review_dismissed": return tr("trok een review in", "dismissed a review");
    default: return event;
  }
}

/// The label after "@author" on a review or comment card, and its tone.
export function eventLabel(e: PullRequestEvent): { text: string; tone: "" | "good" | "bad" } {
  switch (e.kind) {
    case "comment":
      return { text: tr("reageerde", "commented"), tone: "" };
    case "lineComment":
      return { text: tr("reageerde op {place}", "commented on {place}", { place: e.line !== null ? `${e.path}:${e.line}` : e.path }), tone: "" };
    case "review":
      if (e.state === "APPROVED") return { text: tr("keurde goed", "approved"), tone: "good" };
      if (e.state === "CHANGES_REQUESTED") return { text: tr("vroeg om wijzigingen", "requested changes"), tone: "bad" };
      if (e.state === "DISMISSED") return { text: tr("review ingetrokken", "review dismissed"), tone: "" };
      return { text: tr("gaf een review", "reviewed"), tone: "" };
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

// Reading ahead (`PullRequestBackgroundRefresh` and `PullRequestDetailWarmup` on the Mac): the list is read again now and
// then while its page is closed, and after every read the pages you are most likely to open are read too, so opening one
// shows it at once instead of loading.

export type Pace = "full" | "light" | "paused";

/// How much longer each wait is: twice when light, six times paused.
export const slowdown = (pace: Pace) => (pace === "full" ? 1 : pace === "light" ? 2 : 6);

/// Between two background reads of the list at full speed.
export const BACKGROUND_EVERY = 600_000;

/// Whether the list is due for a background read: not read (by its page or in the background) within the stretched wait.
/// A clock that went backwards counts as due.
export function listDue(lastRead: number, now: number, pace: Pace): boolean {
  const elapsed = now - lastRead;
  return elapsed < 0 || elapsed >= BACKGROUND_EVERY * slowdown(pace);
}

/// What was read ahead (or shown) of a pull request: its last update as GitHub said then, and when.
export interface Seen {
  updated: string | null;
  at: number;
}

export interface WarmPick {
  account: string;
  item: PullRequestItem;
}

/// Pages read ahead per pass at full speed; half when light, none paused.
export const WARM_LIMIT = 6;
/// A pull request that did not change is read again after this.
export const WARM_FRESH_FOR = 1_800_000;
/// One that changed waits at least this long since its last read: an opened page reads it again anyway.
export const WARM_MIN_GAP = 300_000;

export const warmCount = (pace: Pace) => (pace === "full" ? WARM_LIMIT : pace === "light" ? WARM_LIMIT / 2 : 0);

export const detailKey = (account: string, repo: string, number: number) => `${account} ${repo}#${number}`;

/// Whether a kept read is worth replacing; a clock that went backwards counts as due.
export function warmDue(kept: Seen, item: PullRequestItem, now: number): boolean {
  const elapsed = now - kept.at;
  if (elapsed < 0) return true;
  const changed = item.updated !== null && kept.updated !== item.updated;
  return elapsed >= (changed ? WARM_MIN_GAP : WARM_FRESH_FOR);
}

/// The pull requests to read ahead now, in order: the open ones that ask for your review first, then your own, newest
/// first. One that was read recently and did not change since is passed over for the next.
export function warmPicks(accounts: AccountPullRequests[], seen: (key: string) => Seen | undefined, now: number, pace: Pace): WarmPick[] {
  const room = warmCount(pace);
  if (room <= 0) return [];
  const newest = (x: PullRequestItem, y: PullRequestItem) => (y.updated ?? "").localeCompare(x.updated ?? "");
  const reviews: WarmPick[] = [];
  const mine: WarmPick[] = [];
  for (const a of accounts) {
    if (a.error) continue;
    reviews.push(...a.reviews.filter((i) => i.state === "open").sort(newest).map((item) => ({ account: a.id, item })));
    mine.push(...a.mine.filter((i) => i.state === "open").sort(newest).map((item) => ({ account: a.id, item })));
  }
  const chosen: WarmPick[] = [];
  const taken = new Set<string>();
  for (const pick of [...reviews, ...mine]) {
    if (chosen.length >= room) break;
    const key = detailKey(pick.account, pick.item.repo, pick.item.number);
    if (taken.has(key)) continue;
    taken.add(key);
    const kept = seen(key);
    if (kept && !warmDue(kept, pick.item, now)) continue;
    chosen.push(pick);
  }
  return chosen;
}
