// The one-line "3 sessions settled · Ctrl+Z" notice under the session list (`UndoLog` on the Mac): what the last list
// action did, for five seconds, with Undo. The same kind of action in a row merges into one line and restarts its five
// seconds. The undo itself is the list's own stack (`session.undo`); this only decides what the line says and when it
// goes. No interface code, so tests use it on its own.
import type { InboxState } from "./agent-inbox";

export type UndoKind = "settled" | "unsettled" | "snoozed" | "pinned" | "unpinned";

export interface UndoEntry {
  kind: UndoKind;
  ids: string[];
  /** The latest action merged into this entry: the five seconds run from it (ms). */
  createdAt: number;
}

export const UNDO_WINDOW_MS = 5_000;

export class UndoLog {
  entries: UndoEntry[] = [];

  /** Same kind as the live top entry merges into it, and restarts its window. */
  record(kind: UndoKind, ids: string[], now: number) {
    this.prune(now);
    const unique = [...new Set(ids)];
    if (!unique.length) return;
    const top = this.entries[this.entries.length - 1];
    if (top && top.kind === kind) {
      top.ids = [...top.ids, ...unique.filter((id) => !top.ids.includes(id))];
      top.createdAt = now;
    } else {
      this.entries.push({ kind, ids: unique, createdAt: now });
    }
  }

  /** The entry the notice shows; null once it is five seconds old. */
  current(now: number): UndoEntry | null {
    for (let i = this.entries.length - 1; i >= 0; i--) {
      if (now - this.entries[i].createdAt < UNDO_WINDOW_MS) return this.entries[i];
    }
    return null;
  }

  /** Takes the current entry off the log. Nothing is undoable after it expired. */
  undo(now: number): UndoEntry | null {
    this.prune(now);
    return this.entries.pop() ?? null;
  }

  private prune(now: number) {
    this.entries = this.entries.filter((e) => now - e.createdAt < UNDO_WINDOW_MS);
  }
}

/** What one list action did, read from the state before and after it; null for anything the notice does not name
 * (folding a project, grouping). */
export function describeChange(before: InboxState, after: InboxState, now: number): { kind: UndoKind; ids: string[] } | null {
  const added = (a: string[], b: string[]) => b.filter((id) => !a.includes(id));
  const settled = added(before.settled, after.settled);
  if (settled.length) return { kind: "settled", ids: settled };
  const reopened = added(after.settled, before.settled);
  if (reopened.length) return { kind: "unsettled", ids: reopened };
  const snoozed = Object.entries(after.snoozed)
    .filter(([id, until]) => until > now && before.snoozed[id] !== until)
    .map(([id]) => id);
  if (snoozed.length) return { kind: "snoozed", ids: snoozed };
  const pinned = added(before.pinned, after.pinned);
  if (pinned.length) return { kind: "pinned", ids: pinned };
  const unpinned = added(after.pinned, before.pinned);
  if (unpinned.length) return { kind: "unpinned", ids: unpinned };
  return null;
}
