// A unified diff (`git diff`, a pull request patch) split into rows for display (UnifiedDiff on the Mac): line numbers
// on both sides, hunk headers, and the changed part of a line that was edited rather than replaced.

export type DiffRowKind = "file" | "hunk" | "context" | "add" | "remove" | "note";

export interface DiffRow {
  /// "file": a file in a diff of several files. "hunk": `text` holds the section after "@@ … @@", if any. "note": "new
  /// file mode", "Binary files … differ", "\ No newline at end of file" and the like.
  kind: DiffRowKind;
  /// The line without its diff prefix ("+", "-", " ").
  text: string;
  /// The line exactly as in the diff.
  raw: string;
  old: number | null;
  new: number | null;
  /// The part of `text` that changed compared with its paired line ([start, end) in string indices), for an edited line.
  changed: [number, number] | null;
}

function row(kind: DiffRowKind, text: string, raw: string, old: number | null = null, nw: number | null = null): DiffRow {
  return { kind, text, raw, old, new: nw, changed: null };
}

export function diffRows(diff: string): DiffRow[] {
  const rows: DiffRow[] = [];
  let old: number | null = null;
  let nw: number | null = null;
  for (const raw of diff.split("\n")) {
    if (raw.startsWith("diff --git ")) {
      old = null;
      nw = null;
      rows.push(row("file", filePath(raw), raw));
    } else if (raw.startsWith("@@")) {
      const h = hunk(raw);
      old = h.old;
      nw = h.new;
      rows.push(row("hunk", h.section, raw, h.old, h.new));
    } else if (old !== null && nw !== null) {
      if (raw.startsWith("+")) {
        rows.push(row("add", raw.slice(1), raw, null, nw));
        nw += 1;
      } else if (raw.startsWith("-")) {
        rows.push(row("remove", raw.slice(1), raw, old, null));
        old += 1;
      } else if (raw.startsWith("\\")) {
        rows.push(row("note", raw.slice(1).trim(), raw));
      } else {
        // Context; some tools strip the space of an empty line.
        rows.push(row("context", raw.startsWith(" ") ? raw.slice(1) : raw, raw, old, nw));
        old += 1;
        nw += 1;
      }
    } else if (raw.startsWith("index ") || raw.startsWith("--- ") || raw.startsWith("+++ ") || raw === "") {
      // File headers: the file row and the line numbers already say this.
      continue;
    } else {
      rows.push(row("note", raw, raw));
    }
  }
  // A trailing newline of the diff leaves an empty context row behind.
  const last = rows[rows.length - 1];
  if (last && last.kind === "context" && last.raw === "") rows.pop();
  // A file row only helps when the diff holds more than one file.
  const shown = rows.filter((r) => r.kind === "file").length < 2 ? rows.filter((r) => r.kind !== "file") : rows;
  markChanges(shown);
  return shown;
}

/// "diff --git a/src/x.rs b/src/x.rs" → "src/x.rs".
export function filePath(header: string): string {
  const at = header.lastIndexOf(" b/");
  return at >= 0 ? header.slice(at + 3) : header.slice("diff --git ".length);
}

/// "@@ -10,4 +12,6 @@ fn name" → { old: 10, new: 12, section: "fn name" }.
export function hunk(header: string): { old: number; new: number; section: string } {
  const start = (marker: string) => {
    const at = header.indexOf(marker);
    if (at < 0) return 1;
    const digits = /^\d+/.exec(header.slice(at + marker.length));
    return digits ? Number(digits[0]) : 1;
  };
  const open = header.indexOf("@@");
  const close = open >= 0 ? header.indexOf("@@", open + 2) : -1;
  const section = close >= 0 ? header.slice(close + 2).trim() : "";
  return { old: start("@@ -"), new: start(" +"), section };
}

/// "@@ -10,4 +12,6 @@ fn name" → "@@ -10,4 +12,6 @@".
export function hunkLabel(header: string): string {
  const open = header.indexOf("@@");
  const close = open >= 0 ? header.indexOf("@@", open + 2) : -1;
  return close >= 0 ? header.slice(0, close + 2) : header;
}

/// Pairs each run of removed lines with the added lines right after it and marks what changed within each pair, so an
/// edit to a few words stands out from a rewritten line.
function markChanges(rows: DiffRow[]) {
  let index = 0;
  while (index < rows.length) {
    if (rows[index].kind !== "remove") {
      index += 1;
      continue;
    }
    let removedEnd = index;
    while (removedEnd < rows.length && rows[removedEnd].kind === "remove") removedEnd += 1;
    let addedEnd = removedEnd;
    while (addedEnd < rows.length && rows[addedEnd].kind === "add") addedEnd += 1;
    const pairs = Math.min(removedEnd - index, addedEnd - removedEnd);
    for (let offset = 0; offset < pairs; offset++) {
      const [before, after] = changedRanges(rows[index + offset].text, rows[removedEnd + offset].text);
      rows[index + offset].changed = before;
      rows[removedEnd + offset].changed = after;
    }
    index = Math.max(addedEnd, index + 1);
  }
}

/// The differing middle of two lines after their common prefix and suffix; null when the lines share too little for a
/// highlight to help (the whole line is then simply new).
export function changedRanges(a: string, b: string): [[number, number] | null, [number, number] | null] {
  let prefix = 0;
  while (prefix < a.length && prefix < b.length && a[prefix] === b[prefix]) prefix += 1;
  let suffix = 0;
  while (suffix < a.length - prefix && suffix < b.length - prefix && a[a.length - 1 - suffix] === b[b.length - 1 - suffix]) suffix += 1;
  const shared = prefix + suffix;
  if (shared === 0 || shared * 4 < Math.min(a.length, b.length)) return [null, null];
  const before: [number, number] = [prefix, a.length - suffix];
  const after: [number, number] = [prefix, b.length - suffix];
  return [before[0] < before[1] ? before : null, after[0] < after[1] ? after : null];
}

/// The rows of an edit's line diff (`DiffLine`s, "+ text", "- text", "  text"): no line numbers, but the same tints and
/// highlights of what changed within an edited line.
export function lineRows(lines: { kind: "add" | "remove" | "context"; text: string }[]): DiffRow[] {
  const rows = lines.map((l) => row(l.kind, /^[+\- ] /.test(l.text) ? l.text.slice(2) : l.text, l.text));
  markChanges(rows);
  return rows;
}
