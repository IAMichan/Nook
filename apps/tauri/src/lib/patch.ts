// Lines of a unified diff as the iPhone reads them (`PatchPositions`, `SessionChangesView`): each line's number on the new
// side, where a comment on it lands on GitHub (its line and side), and the comment for a picked range.
import type { LineComment } from "./companion";

export interface Position { line: number; side: "LEFT" | "RIGHT" }

/** Each line's position; null for a hunk header and for "\ No newline at end of file". */
export function positions(lines: string[]): (Position | null)[] {
  let old = 0, now = 0, inHunk = false;
  const after = (marker: string, line: string) => {
    const i = line.indexOf(marker);
    if (i < 0) return 0;
    const m = /^\d+/.exec(line.slice(i + marker.length));
    return m ? Number(m[0]) : 0;
  };
  return lines.map((line) => {
    if (line.startsWith("@@")) {
      old = after(" -", line);
      now = after(" +", line);
      inHunk = true;
      return null;
    }
    if (!inHunk || line.startsWith("\\")) return null;
    if (line.startsWith("-")) return { line: old++, side: "LEFT" };
    if (line.startsWith("+")) return { line: now++, side: "RIGHT" };
    old++;
    return { line: now++, side: "RIGHT" };
  });
}

/** The number shown beside a line: its line in the new file; none for a removed line or a hunk header. */
export function newNumbers(lines: string[]): (number | null)[] {
  return positions(lines).map((p) => (p && p.side === "RIGHT" ? p.line : null));
}

/** A review comment on the picked lines (indexes, inclusive): on the last one, from the first on the same side. */
export function lineComment(path: string, from: number, to: number, pos: (Position | null)[], body: string): LineComment | null {
  const inRange = pos.slice(Math.min(from, to), Math.max(from, to) + 1).filter((p): p is Position => !!p);
  const end = inRange[inRange.length - 1];
  if (!end) return null;
  const start = inRange.find((p) => p.side === end.side);
  return { path, line: end.line, side: end.side, body, startLine: start && start.line < end.line ? start.line : undefined };
}

/** The block a comment on a session's changes becomes in its message (the Mac's `ReviewComments`). */
export function reviewComment(path: string, lines: string[], numbers: (number | null)[], from: number, to: number, text: string): string {
  const picked = lines.slice(Math.min(from, to), Math.max(from, to) + 1);
  const first = numbers.slice(Math.min(from, to), Math.max(from, to) + 1).find((n) => n !== null);
  const line = first != null ? ` line="${first}"` : "";
  return `<review_comment file="${path}"${line}>\n> ${picked.join("\n> ")}\n${text}\n</review_comment>`;
}

export const REVIEW_INTRO = "Review comments on your changes. Address each one:";

/** Adds a review comment under what the composer holds, opening a message with the intro (as the iPhone does). */
export function withReviewComment(message: string, comment: string): string {
  const current = message.trim();
  return (current || REVIEW_INTRO) + "\n\n" + comment;
}
