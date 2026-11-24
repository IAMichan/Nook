// How much of the agent's work a session's timeline shows (the Mac's `TimelineDetail`, Settings › Sessions › "Agent's
// work in the timeline"). Everything: every step. Hide finished steps: a command, edit, read or search that went fine is
// left out; one that runs, waits or failed stays. Hide all steps: every command, edit, read and search is left out, its
// thinking stays. Zen: only the conversation, your messages and the agent's final answer of each turn. What waits on you
// or went wrong (approvals, errors) and Nook's own lines (a switch, a suggestion, a page) always stay. Pure, so the rules
// are tested; the timeline view calls `filterTimeline`.
import type { RunEvent } from "./api";

export type TimelineDetail = "everything" | "hideSucceeded" | "noTools" | "zen";

export const TIMELINE_DETAILS: TimelineDetail[] = ["everything", "hideSucceeded", "noTools", "zen"];

/// A stored value as a detail; anything unknown (or nothing) shows everything.
export function timelineDetail(raw: string | null | undefined): TimelineDetail {
  return TIMELINE_DETAILS.includes(raw as TimelineDetail) ? (raw as TimelineDetail) : "everything";
}

/// A step that is over and went fine; a running background command, a pending step or a failure is not.
function succeeded(event: RunEvent): boolean {
  switch (event.state) {
    case "running": case "pending": case "failed": case "denied": case "expired": return false;
    default: return true;
  }
}

/// Whether the event stays on its own (Zen's "final answer of a turn" is decided in `filterTimeline`).
export function keeps(detail: TimelineDetail, event: RunEvent): boolean {
  switch (event.kind) {
    case "tool": case "fileChange":
      return detail === "everything" ? true : detail === "hideSucceeded" ? !succeeded(event) : false;
    case "thinking":
      return detail !== "zen";
    default:
      return true;
  }
}

export function filterTimeline(events: RunEvent[], detail: TimelineDetail): RunEvent[] {
  if (detail === "everything") return events;
  if (detail !== "zen") return events.filter((e) => keeps(detail, e));
  // Zen: of the agent's messages in a turn (everything between two of yours) only the last one stays.
  const finalAnswers = new Set<string>();
  let lastAnswer: string | null = null;
  for (const e of events) {
    if (e.kind === "user") {
      if (lastAnswer) finalAnswers.add(lastAnswer);
      lastAnswer = null;
    } else if (e.kind === "assistant") lastAnswer = e.id;
  }
  if (lastAnswer) finalAnswers.add(lastAnswer);
  return events.filter((e) => (e.kind === "assistant" ? finalAnswers.has(e.id) : keeps(detail, e)));
}
