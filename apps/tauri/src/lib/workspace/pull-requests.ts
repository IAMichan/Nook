// Linked pull requests, stacked PR ordering, row badges, and session branch tray helpers
// (`LinkedPullRequests`, `PullRequestBadge`, `SessionBranches`, `PullRequestSync` on macOS, AG-104).

export type PullRequestState = "draft" | "open" | "merged" | "closed";

export type SourceControlHostWire =
  | { kind: "github" }
  | { kind: "gitlab" }
  | { kind: "bitbucket" }
  | { kind: "gitea" }
  | { kind: "forgejo" }
  | { kind: "azureDevOps" }
  | { kind: "gitcafe" }
  | { kind: "unknown"; host: string };

export interface PullRequestLink {
  host: SourceControlHostWire;
  repository: string;
  number: number;
  url: string;
  title?: string | null;
  state: PullRequestState;
  updatedAt?: string | null;
  baseBranch?: string | null;
  headBranch?: string | null;
  conflicted?: boolean;
}

export type LinkedSource = "branch" | "earlier" | "added";

export interface LinkedPullRequest {
  link: PullRequestLink;
  source: LinkedSource;
  depth: number;
}

export type BadgeGlyph = "draft" | "open" | "conflict" | "merged" | "closed" | "stack";

export type BadgeLabel =
  | { kind: "number"; number: number }
  | { kind: "numberPlus"; number: number; extra: number }
  | { kind: "stack"; count: number; merged: number };

export interface PullRequestBadge {
  glyph: BadgeGlyph;
  label: BadgeLabel;
}

export interface SessionBranchRow {
  branch: string | null;
  pullRequest: PullRequestLink | null;
  isCurrent: boolean;
}

export interface PullRequestSyncSnapshot {
  links: Record<string, PullRequestLink[]>;
  folderLinks: Record<string, PullRequestLink[]>;
  earlier: Record<string, PullRequestLink[]>;
  earlierBranches: Record<string, string[]>;
  added: Record<string, PullRequestLink[]>;
  dismissed: Record<string, string[]>;
  syncedAt: Record<string, string>;
}

export function emptyPullRequestSyncSnapshot(): PullRequestSyncSnapshot {
  return {
    links: {},
    folderLinks: {},
    earlier: {},
    earlierBranches: {},
    added: {},
    dismissed: {},
    syncedAt: {},
  };
}

export const SHOWN_WHEN_FOLDED = 3;

export function isPrOpen(state: PullRequestState): boolean {
  return state === "draft" || state === "open";
}

export function hasConflict(link: PullRequestLink): boolean {
  return isPrOpen(link.state) && !!link.conflicted;
}

export function hostKey(host: SourceControlHostWire | undefined): string {
  if (!host) return "unknown:";
  switch (host.kind) {
    case "github":
      return "github";
    case "gitlab":
      return "gitlab";
    case "bitbucket":
      return "bitbucket";
    case "gitea":
      return "gitea";
    case "forgejo":
      return "forgejo";
    case "azureDevOps":
      return "azure-devops";
    case "gitcafe":
      return "gitcafe";
    case "unknown":
      return `unknown:${host.host ?? ""}`;
  }
}

export function linkId(link: PullRequestLink): string {
  return `${hostKey(link.host)}:${link.repository.toLowerCase()}#${link.number}`;
}

export function placeId(link: PullRequestLink): string {
  return linkId(link);
}

export function sessionKeyFor(runId: string | null | undefined, directory: string): string {
  return runId && runId.trim() ? runId.trim() : directory;
}

export function folderKeyFor(path: string, branch: string): string {
  return `${path}\n${branch}`;
}

function updatedMs(link: PullRequestLink): number {
  if (!link.updatedAt) return 0;
  const parsed = Date.parse(link.updatedAt);
  return Number.isFinite(parsed) ? parsed : 0;
}

/** True when at least two links form a stacked branch chain (one's baseBranch is another's headBranch in the same repo). */
export function isStack(links: PullRequestLink[]): boolean {
  if (links.length < 2) return false;
  const heads = new Map<string, Set<string>>();
  for (const link of links) {
    if (!link.headBranch) continue;
    const repo = link.repository.toLowerCase();
    let set = heads.get(repo);
    if (!set) {
      set = new Set();
      heads.set(repo, set);
    }
    set.add(link.headBranch);
  }
  return links.some((link) => {
    if (!link.baseBranch || link.baseBranch === link.headBranch) return false;
    return heads.get(link.repository.toLowerCase())?.has(link.baseBranch) ?? false;
  });
}

/** Orders links with stacked branches placed under their parent (`depth` = stack nesting level). */
export function orderStack(links: PullRequestLink[]): { link: PullRequestLink; depth: number }[] {
  if (links.length === 0) return [];
  const sorted = [...links].sort((a, b) => a.number - b.number);
  const byRepoHead = new Map<string, number>();
  sorted.forEach((link, idx) => {
    if (link.headBranch) {
      const key = `${link.repository.toLowerCase()}\n${link.headBranch}`;
      if (!byRepoHead.has(key)) byRepoHead.set(key, idx);
    }
  });

  const parent: (number | null)[] = sorted.map((link, idx) => {
    if (!link.baseBranch || link.baseBranch === link.headBranch) return null;
    const p = byRepoHead.get(`${link.repository.toLowerCase()}\n${link.baseBranch}`);
    return p !== undefined && p !== idx ? p : null;
  });

  // Guard against branch cycles.
  for (let i = 0; i < sorted.length; i++) {
    const seen = new Set<number>([i]);
    let cur = parent[i];
    while (cur !== null) {
      if (seen.has(cur)) {
        parent[i] = null;
        break;
      }
      seen.add(cur);
      cur = parent[cur];
    }
  }

  const children = new Map<number, number[]>();
  const roots: number[] = [];
  for (let i = 0; i < sorted.length; i++) {
    const p = parent[i];
    if (p !== null) {
      const list = children.get(p) ?? [];
      list.push(i);
      children.set(p, list);
    } else {
      roots.push(i);
    }
  }

  const out: { link: PullRequestLink; depth: number }[] = [];
  const visited = new Set<number>();
  function walk(idx: number, depth: number) {
    if (visited.has(idx)) return;
    visited.add(idx);
    out.push({ link: sorted[idx], depth });
    for (const child of children.get(idx) ?? []) {
      walk(child, depth + 1);
    }
  }
  for (const r of roots) walk(r, 0);
  for (let i = 0; i < sorted.length; i++) {
    if (!visited.has(i)) walk(i, 0);
  }
  return out;
}

/** Merges current-branch, earlier-branch, and manually added PRs with deduplication, dismissal filtering, and stack ordering. */
export function linkedPullRequests(
  snapshot: PullRequestSyncSnapshot,
  runId: string | null | undefined,
  directory: string,
  branch: string | null | undefined,
): LinkedPullRequest[] {
  const key = sessionKeyFor(runId, directory);
  const current =
    (runId && snapshot.links[runId]) ||
    (branch ? snapshot.folderLinks[folderKeyFor(directory, branch)] : undefined) ||
    [];
  const earlier = (runId && snapshot.earlier[runId]) || [];
  const yours = snapshot.added[key] || [];
  const dismissed = new Set(snapshot.dismissed[key] || []);

  const raw: { link: PullRequestLink; source: LinkedSource }[] = [];
  const seen = new Set<string>();

  const push = (items: PullRequestLink[], source: LinkedSource) => {
    for (const link of items) {
      const id = linkId(link);
      const place = placeId(link);
      if (dismissed.has(id) || dismissed.has(place)) continue;
      if (seen.has(place)) continue;
      seen.add(place);
      raw.push({ link, source });
    }
  };

  push(current, "branch");
  push(earlier, "earlier");
  push(yours, "added");

  if (raw.length === 0) return [];
  const sourceByPlace = new Map<string, LinkedSource>();
  for (const entry of raw) sourceByPlace.set(placeId(entry.link), entry.source);

  const ordered = orderStack(raw.map((r) => r.link));
  const byPlace = new Map<string, { link: PullRequestLink; depth: number; pos: number }>();
  ordered.forEach((entry, pos) => {
    byPlace.set(placeId(entry.link), { ...entry, pos });
  });

  // Sort: open/draft first, then closed/merged; within a stack keep parent -> child order.
  const lines: LinkedPullRequest[] = ordered.map(({ link, depth }) => ({
    link,
    source: sourceByPlace.get(placeId(link)) ?? "added",
    depth,
  }));

  if (isStack(raw.map((r) => r.link))) {
    return lines;
  }

  return lines.sort((a, b) => {
    const openDiff = Number(isPrOpen(b.link.state)) - Number(isPrOpen(a.link.state));
    if (openDiff !== 0) return openDiff;
    const updDiff = updatedMs(b.link) - updatedMs(a.link);
    if (updDiff !== 0) return updDiff;
    return b.link.number - a.link.number;
  });
}

export interface SessionPullRequestSummary {
  current: PullRequestLink[];
  earlier: PullRequestLink[];
  all: PullRequestLink[];
  linked: LinkedPullRequest[];
  badge: PullRequestBadge | null;
}

export function sessionPullRequests(
  snapshot: PullRequestSyncSnapshot,
  runId: string | null | undefined,
  directory: string,
  branch: string | null | undefined,
): SessionPullRequestSummary {
  const linked = linkedPullRequests(snapshot, runId, directory, branch);
  const current = linked.filter((l) => l.source === "branch" || l.source === "added").map((l) => l.link);
  const earlier = linked.filter((l) => l.source === "earlier").map((l) => l.link);
  const all = linked.map((l) => l.link);
  const badge = badgeFromLinks(all);
  return { current, earlier, all, linked, badge };
}

export function badgeGlyphForLink(link: PullRequestLink): Exclude<BadgeGlyph, "stack"> {
  if (hasConflict(link)) return "conflict";
  return link.state;
}

/** Compact row badge matching macOS `PullRequestBadge.from(_:)`: `#12`, `#12 +2`, or `Stack of 3` / `1 of 3 merged`. */
export function badgeFromLinks(links: PullRequestLink[]): PullRequestBadge | null {
  if (links.length === 0) return null;
  if (links.length > 1 && isStack(links)) {
    const merged = links.filter((l) => l.state === "merged").length;
    const glyph: BadgeGlyph = links.some((l) => isPrOpen(l.state))
      ? "stack"
      : merged > 0
        ? "merged"
        : "closed";
    return { glyph, label: { kind: "stack", count: links.length, merged } };
  }
  const primary = [...links].sort((a, b) => {
    const openDiff = Number(isPrOpen(b.state)) - Number(isPrOpen(a.state));
    if (openDiff !== 0) return openDiff;
    if (b.number !== a.number) return b.number - a.number;
    return updatedMs(b) - updatedMs(a);
  })[0];
  const glyph = badgeGlyphForLink(primary);
  const label: BadgeLabel =
    links.length === 1
      ? { kind: "number", number: primary.number }
      : { kind: "numberPlus", number: primary.number, extra: links.length - 1 };
  return { glyph, label };
}

/** Builds branch tray rows (oldest first, current last), matching macOS `SessionBranches.rows`. */
export function sessionBranchRows(
  snapshot: PullRequestSyncSnapshot,
  runId: string | null | undefined,
  directory: string,
  currentBranch: string | null | undefined,
): SessionBranchRow[] {
  const key = sessionKeyFor(runId, directory);
  const current = currentBranch && currentBranch.trim() ? currentBranch.trim() : null;
  const earlierNames = (runId && snapshot.earlierBranches[runId]) || [];
  const earlierLinks = (runId && snapshot.earlier[runId]) || [];
  const currentLinks =
    (runId && snapshot.links[runId]) ||
    (current ? snapshot.folderLinks[folderKeyFor(directory, current)] : undefined) ||
    [];
  const addedLinks = snapshot.added[key] || [];
  const dismissed = new Set(snapshot.dismissed[key] || []);

  const keep = (l: PullRequestLink) => !dismissed.has(linkId(l)) && !dismissed.has(placeId(l));
  const cleanEarlier = earlierLinks.filter(keep);
  const cleanCurrent = currentLinks.filter(keep);
  const cleanAdded = addedLinks.filter(keep);

  const newestForBranch = (branch: string): PullRequestLink | null => {
    const hits = cleanEarlier.filter((l) => l.headBranch === branch);
    if (!hits.length) return null;
    return hits.sort((a, b) => updatedMs(b) - updatedMs(a) || b.number - a.number)[0];
  };

  const own = cleanCurrent.filter((l) => !l.headBranch || l.headBranch === current);
  const picked =
    own.find((l) => isPrOpen(l.state)) ??
    [...own].sort((a, b) => updatedMs(b) - updatedMs(a) || b.number - a.number)[0] ??
    null;
  const pickedPlace = picked ? placeId(picked) : null;

  const names = earlierNames.filter((b) => b !== current);
  const rows: SessionBranchRow[] = names.map((b) => ({
    branch: b,
    pullRequest: newestForBranch(b),
    isCurrent: false,
  }));
  const seen = new Set<string>();
  for (const r of rows) {
    if (r.pullRequest) seen.add(placeId(r.pullRequest));
  }

  for (const link of cleanEarlier) {
    if (!link.url) continue;
    const covered = !!link.headBranch && (names.includes(link.headBranch) || link.headBranch === current);
    if (covered) continue;
    const place = placeId(link);
    if (place === pickedPlace || seen.has(place)) continue;
    seen.add(place);
    rows.push({ branch: link.headBranch ?? null, pullRequest: link, isCurrent: false });
  }

  for (const link of [...own].sort((a, b) => a.number - b.number)) {
    if (!link.url) continue;
    const place = placeId(link);
    if (place === pickedPlace || seen.has(place)) continue;
    seen.add(place);
    rows.push({ branch: current, pullRequest: link, isCurrent: true });
  }

  for (const link of cleanAdded) {
    if (!link.url) continue;
    const place = placeId(link);
    if (place === pickedPlace || seen.has(place)) continue;
    seen.add(place);
    rows.push({ branch: link.headBranch ?? null, pullRequest: link, isCurrent: link.headBranch === current && !!current });
  }

  const fallback = picked ?? (current ? newestForBranch(current) : null);
  const mine = fallback && !seen.has(placeId(fallback)) ? fallback : null;
  if (rows.length > 0 || mine) {
    rows.push({ branch: current, pullRequest: mine, isCurrent: true });
  }
  return rows;
}

export function foldBranchRows(
  rows: SessionBranchRow[],
  open: boolean,
): { shown: SessionBranchRow[]; hiddenCount: number; hiddenPrCount: number } {
  if (open || rows.length <= SHOWN_WHEN_FOLDED + 1) {
    return { shown: rows, hiddenCount: 0, hiddenPrCount: 0 };
  }
  const split = rows.length - SHOWN_WHEN_FOLDED;
  const hidden = rows.slice(0, split);
  return {
    shown: rows.slice(split),
    hiddenCount: hidden.length,
    hiddenPrCount: hidden.filter((r) => r.pullRequest !== null).length,
  };
}
