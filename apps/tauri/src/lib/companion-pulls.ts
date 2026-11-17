// The phone's pull request list as the Mac's Agents › Pull requests, the same rules as the iPhone's `PullList`
// (packages/protocol/Sources/CompanionPullRequests.swift): the chips with counts, the search with its qualifiers, the
// state, the order and the grouping.
import type { PullDigest } from "./companion";

export type Attention = "review" | "failing" | "ready";
export type PullState = "open" | "closed" | "merged" | "all";
export type PullSort = "attention" | "readiness" | "blockedOnMe" | "recent" | "oldest" | "largest" | "smallest";
export type PullGrouping = "involvement" | "repository";

export const ATTENTIONS: Attention[] = ["review", "failing", "ready"];
export const STATES: PullState[] = ["open", "closed", "merged", "all"];
export const SORTS: PullSort[] = ["attention", "readiness", "blockedOnMe", "recent", "oldest", "largest", "smallest"];

const isOpen = (p: PullDigest) => p.state === "open" || p.state === "draft";
export const isReadyToMerge = (p: PullDigest) => p.state === "open" && !p.conflict && p.ci === "passing" && p.review === "approved";
const size = (p: PullDigest) => (p.additions ?? 0) + (p.deletions ?? 0);

export function attends(kind: Attention, p: PullDigest): boolean {
  if (!isOpen(p)) return false;
  if (kind === "review") return p.group === "review";
  if (kind === "failing") return p.group === "mine" && p.ci === "failing";
  return p.group === "mine" && isReadyToMerge(p);
}

export function inState(state: PullState, p: PullDigest): boolean {
  if (state === "open") return isOpen(p);
  if (state === "all") return true;
  return p.state === state;
}

export interface PullQuery {
  words: string[]; labels: string[][]; excludedLabels: string[]; author?: string; repo?: string; excludedRepos: string[];
  branch?: string; draft?: boolean; review?: string; checks?: string;
}

/** The search as the Mac reads it: words, `label:` (`label:a,b`, `-label:`), `author:`, `repo:` (`-repo:`), `branch:`
 * (`head:`), `draft:true|false`, `review:`, `checks:` (`status:`); a bare scoped label ("area:ui") is a label. */
export function parseQuery(raw: string): PullQuery {
  const q: PullQuery = { words: [], labels: [], excludedLabels: [], excludedRepos: [] };
  for (const token of raw.split(/\s+/).filter(Boolean)) {
    const negated = token.startsWith("-");
    const body = negated ? token.slice(1) : token;
    const colon = body.indexOf(":");
    if (colon <= 0) { q.words.push(token.toLowerCase()); continue; }
    const key = body.slice(0, colon).toLowerCase();
    const value = body.slice(colon + 1).replace(/^["']|["']$/g, "");
    if (!value) { q.words.push(token.toLowerCase()); continue; }
    const lower = value.toLowerCase();
    if (key === "label") {
      const names = lower.split(",").filter(Boolean);
      if (negated) q.excludedLabels.push(...names); else q.labels.push(names);
    } else if (key === "author" && !negated) q.author = lower.replace(/^@/, "");
    else if (key === "repo") { if (negated) q.excludedRepos.push(lower); else q.repo = lower; }
    else if ((key === "branch" || key === "head") && !negated) q.branch = lower;
    else if (key === "draft" && (lower === "true" || lower === "false")) q.draft = (lower === "true") !== negated;
    else if (key === "review" && !negated) {
      const review = ({ approved: "approved", changes: "changesRequested", "changes-requested": "changesRequested", changes_requested: "changesRequested", required: "required", "review-required": "required", none: "none" } as Record<string, string>)[lower];
      if (review) q.review = review; else q.words.push(token.toLowerCase());
    } else if ((key === "checks" || key === "status") && !negated) {
      const checks = ({ passing: "passing", success: "passing", failing: "failing", failure: "failing", pending: "pending", running: "pending" } as Record<string, string>)[lower];
      if (checks) q.checks = checks; else q.words.push(token.toLowerCase());
    } else if (negated) q.excludedLabels.push(body.toLowerCase());
    else q.labels.push([body.toLowerCase()]);
  }
  return q;
}

export function matches(q: PullQuery, p: PullDigest): boolean {
  if (q.author && p.author.toLowerCase() !== q.author) return false;
  if (q.repo && p.repo.toLowerCase() !== q.repo) return false;
  if (q.excludedRepos.includes(p.repo.toLowerCase())) return false;
  if (q.branch && !(p.headBranch ?? "").toLowerCase().includes(q.branch)) return false;
  if (q.draft !== undefined && (p.state === "draft") !== q.draft) return false;
  if (q.review && p.review !== q.review) return false;
  if (q.checks && p.ci !== q.checks) return false;
  const held = new Set((p.labels ?? []).map((l) => l.toLowerCase()));
  if (!q.labels.every((group) => group.some((l) => held.has(l)))) return false;
  if (q.excludedLabels.some((l) => held.has(l))) return false;
  if (!q.words.length) return true;
  const text = `${p.repo}#${p.number} ${p.title} @${p.author} ${p.headBranch ?? ""}`.toLowerCase();
  return q.words.every((word) => {
    const digits = word.startsWith("#") ? word.slice(1) : word;
    if (digits && /^\d+$/.test(digits)) return p.number === Number(digits) || (!word.startsWith("#") && text.includes(word));
    return text.includes(word);
  });
}

const urgency = (p: PullDigest) => (!isOpen(p) ? 3 : p.group === "review" ? 0 : p.group === "mine" && p.ci === "failing" ? 1 : 2);
function readiness(p: PullDigest): number {
  if (!isOpen(p)) return 4;
  if (p.conflict) return 3;
  if (p.state === "draft") return 2;
  if (p.ci === "passing") return p.review === "approved" ? 0 : 1;
  return 2;
}
function blockedOnMe(p: PullDigest): number {
  if (!isOpen(p)) return 9;
  if (p.group === "review") return 0;
  if (p.group !== "mine") return 8;
  if (p.conflict) return 1;
  if (p.review === "changesRequested") return 2;
  if (p.ci === "failing") return 3;
  if (p.state === "draft") return 4;
  if (p.ci === "passing" && p.review === "approved") return 6;
  return 5;
}

export function sorted(pulls: PullDigest[], sort: PullSort): PullDigest[] {
  const key = (p: PullDigest): number[] => {
    const updated = p.updated ?? 0;
    const open = isOpen(p) ? 0 : 1;
    switch (sort) {
      case "attention": return [urgency(p), -updated, 0];
      case "readiness": return [readiness(p), size(p), -updated];
      case "blockedOnMe": return [blockedOnMe(p), -updated, 0];
      case "recent": return [open, -updated, 0];
      case "oldest": return [open, updated, 0];
      case "largest": return [open, -size(p), -updated];
      case "smallest": return [open, size(p), -updated];
    }
  };
  return pulls.map((p, i) => ({ p, i, k: key(p) })).sort((a, b) => {
    for (let j = 0; j < 3; j++) if (a.k[j] !== b.k[j]) return a.k[j] - b.k[j];
    return a.i - b.i;
  }).map((x) => x.p);
}

export interface PullSection { key: string; pulls: PullDigest[] }

/** What the list shows: state, search and chip applied, sorted, in sections (review, mine, watched, linked; or by repo). */
export function sections(pulls: PullDigest[], opts: { query?: string; state?: PullState; attention?: Attention | null; sort?: PullSort; grouping?: PullGrouping } = {}): PullSection[] {
  const q = parseQuery(opts.query ?? "");
  const state = opts.state ?? "open";
  const kept = sorted(pulls.filter((p) => inState(state, p) && matches(q, p) && (!opts.attention || attends(opts.attention, p))), opts.sort ?? "attention");
  if ((opts.grouping ?? "involvement") === "involvement") {
    return ["review", "mine", "watched", "linked"].map((key) => ({ key, pulls: kept.filter((p) => p.group === key) })).filter((s) => s.pulls.length);
  }
  const out: PullSection[] = [];
  const index = new Map<string, number>();
  for (const p of kept) {
    const k = p.repo.toLowerCase();
    const at = index.get(k);
    if (at !== undefined) out[at].pulls.push(p);
    else { index.set(k, out.length); out.push({ key: p.repo, pulls: [p] }); }
  }
  return out;
}

/** The chips' counts: the state and search applied, not the chip itself, as on the Mac. */
export function counted(pulls: PullDigest[], query = "", state: PullState = "open"): Record<Attention, number> {
  const q = parseQuery(query);
  const kept = pulls.filter((p) => inState(state, p) && matches(q, p));
  return { review: kept.filter((p) => attends("review", p)).length, failing: kept.filter((p) => attends("failing", p)).length, ready: kept.filter((p) => attends("ready", p)).length };
}
