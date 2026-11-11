// The Agents list as sections (`InboxLayout` on the Mac): pure decisions about which row sits where. The view only draws
// what comes back. Nesting of delegated sessions is left out: Nook for Windows does not track which session started which.

export type Attention = "approval" | "input" | "failed" | "limited" | "working" | "ready" | "idle" | "finished";

const attentionRank: Record<Attention, number> = {
  approval: 0, input: 1, failed: 2, limited: 3, working: 4, ready: 5, idle: 6, finished: 7,
};

/// Something only you can unblock.
export const needsYou = (a: Attention) => a === "approval" || a === "input";

export interface InboxRow {
  id: string;
  title: string;
  project: string;
  attention: Attention;
  /// Milliseconds since the epoch of the newest activity.
  lastActivity: number;
  /// A turn ended but background work (subagents) goes on.
  hasBackgroundWork?: boolean;
  /// Changed since the user last looked.
  unread?: boolean;
}

/// What the user decided about the list. Stored, so it survives a restart.
export interface InboxState {
  /// Pinned ids; the array order is the user's order.
  pinned: string[];
  settled: string[];
  /// Snoozed ids with the moment they wake up (ms).
  snoozed: Record<string, number>;
  groupByProject: boolean;
  collapsedProjects: string[];
}

export const emptyState = (): InboxState => ({ pinned: [], settled: [], snoozed: {}, groupByProject: true, collapsedProjects: [] });

export type SectionKind = "pinned" | "active" | "working" | "snoozed" | "settled";

export interface InboxEntry {
  row: InboxRow;
  /// Drawn quieter: nothing here asks for you.
  receded: boolean;
  /// Came back from a snooze.
  woke: boolean;
}

export interface InboxSection {
  kind: SectionKind;
  rows: InboxEntry[];
  /// Settled paging: how many more rows "Show 10 more" would reveal.
  hiddenCount: number;
}

export interface ProjectGroup {
  project: string;
  rows: { kind: SectionKind; entry: InboxEntry }[];
  needsYou: boolean;
}

export const settledPage = 10;

/// The selected row and a question never recede; work in progress always does; a finished row only once it was read.
export function receded(row: InboxRow, woke: boolean, selected: boolean): boolean {
  if (selected || row.attention === "input") return false;
  if (row.attention === "working" || (row.hasBackgroundWork && !needsYou(row.attention))) return true;
  if (row.attention === "ready" || row.attention === "approval") return !(row.unread ?? true) && !woke;
  return false;
}

const isWorking = (row: InboxRow) =>
  row.attention === "working" ? true : row.attention === "failed" || row.attention === "limited" ? false : !!row.hasBackgroundWork;

const newestFirst = (a: InboxEntry, b: InboxEntry) =>
  a.row.lastActivity !== b.row.lastActivity ? b.row.lastActivity - a.row.lastActivity : a.row.id.localeCompare(b.row.id);

/// Sections in display order; empty ones are left out. Every row lands in exactly one section.
export function sections(rows: InboxRow[], state: InboxState, opts: { showWorking: boolean; now: number; settledLimit?: number; selectedId?: string | null }): InboxSection[] {
  const pinned: InboxEntry[] = [], active: InboxEntry[] = [], working: InboxEntry[] = [], snoozed: InboxEntry[] = [], settled: InboxEntry[] = [];
  const pinRank = new Map(state.pinned.map((id, i) => [id, i]));
  const settledIds = new Set(state.settled);

  for (const row of rows) {
    const isPinned = pinRank.has(row.id);
    const until = state.snoozed[row.id];
    // What waits for you is never hidden: a snoozed session wakes when something needs you.
    const hidden = until !== undefined && until > opts.now && !needsYou(row.attention);
    const woke = until !== undefined && !hidden;
    const entry = (w = false): InboxEntry => ({ row, receded: receded(row, w, row.id === opts.selectedId), woke: w });
    if (isPinned) pinned.push(entry(woke));
    else if (settledIds.has(row.id) && !needsYou(row.attention)) settled.push(entry());
    else if (hidden) snoozed.push(entry());
    else if (opts.showWorking && !needsYou(row.attention) && isWorking(row)) working.push(entry());
    else active.push(entry(woke));
  }

  pinned.sort((a, b) => (pinRank.get(a.row.id) ?? 1e9) - (pinRank.get(b.row.id) ?? 1e9) || b.row.lastActivity - a.row.lastActivity || a.row.id.localeCompare(b.row.id));
  active.sort((a, b) => attentionRank[a.row.attention] - attentionRank[b.row.attention] || newestFirst(a, b));
  working.sort(newestFirst);
  snoozed.sort((a, b) => (state.snoozed[a.row.id] ?? Infinity) - (state.snoozed[b.row.id] ?? Infinity) || a.row.id.localeCompare(b.row.id));
  settled.sort(newestFirst);

  const limit = Math.max(0, opts.settledLimit ?? settledPage);
  const page = settled.slice(0, limit);
  // The open session stays on the settled page even when it is further down than the page reaches.
  const open = settled.slice(limit).find((e) => e.row.id === opts.selectedId);
  if (open) page.push(open);

  const result: InboxSection[] = [
    { kind: "working", rows: working, hiddenCount: 0 },
    { kind: "pinned", rows: pinned, hiddenCount: 0 },
    { kind: "active", rows: active, hiddenCount: 0 },
    { kind: "snoozed", rows: snoozed, hiddenCount: 0 },
    { kind: "settled", rows: page, hiddenCount: settled.length - page.length },
  ];
  return result.filter((s) => s.rows.length > 0);
}

/// The Working and Active rows per project. Projects keep a fixed place (by name), so activity in one never moves the
/// whole folder; inside a project the newest session comes first. Pinned, snoozed and settled keep their own sections.
export function projectGroups(list: InboxSection[]): ProjectGroup[] {
  const groups = new Map<string, ProjectGroup>();
  for (const section of list) {
    if (section.kind !== "working" && section.kind !== "active") continue;
    for (const entry of section.rows) {
      const group = groups.get(entry.row.project) ?? { project: entry.row.project, rows: [], needsYou: false };
      group.rows.push({ kind: section.kind, entry });
      group.needsYou ||= needsYou(entry.row.attention) || (entry.row.attention === "failed");
      groups.set(entry.row.project, group);
    }
  }
  return [...groups.values()]
    .map((g) => ({ ...g, rows: [...g.rows].sort((a, b) => b.entry.row.lastActivity - a.entry.row.lastActivity) }))
    .sort((a, b) => a.project.localeCompare(b.project, undefined, { numeric: true, sensitivity: "base" }) || (a.project < b.project ? -1 : 1));
}

/// Every whitespace-separated token must occur in title or project, ignoring case and diacritics.
export function filterRows(rows: InboxRow[], query: string): InboxRow[] {
  const fold = (t: string) => t.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase();
  const tokens = fold(query).split(/\s+/).filter(Boolean);
  if (!tokens.length) return rows;
  return rows.filter((r) => {
    const hay = fold(`${r.title} ${r.project}`);
    return tokens.every((t) => hay.includes(t));
  });
}

// What the row menu does to the stored state.
export function pin(state: InboxState, id: string): InboxState {
  return { ...state, pinned: [id, ...state.pinned.filter((x) => x !== id)] };
}
export function unpin(state: InboxState, id: string): InboxState {
  return { ...state, pinned: state.pinned.filter((x) => x !== id) };
}
/// Settling a pinned thread unpins it.
export function settle(state: InboxState, id: string): InboxState {
  return { ...state, settled: [...new Set([...state.settled, id])], pinned: state.pinned.filter((x) => x !== id) };
}
export function unsettle(state: InboxState, id: string): InboxState {
  return { ...state, settled: state.settled.filter((x) => x !== id) };
}
export function snooze(state: InboxState, id: string, until: number): InboxState {
  return { ...state, snoozed: { ...state.snoozed, [id]: until } };
}
export function wake(state: InboxState, id: string): InboxState {
  const { [id]: _gone, ...rest } = state.snoozed;
  return { ...state, snoozed: rest };
}
export function toggleProject(state: InboxState, project: string): InboxState {
  const folded = state.collapsedProjects.includes(project);
  return { ...state, collapsedProjects: folded ? state.collapsedProjects.filter((p) => p !== project) : [...state.collapsedProjects, project] };
}
