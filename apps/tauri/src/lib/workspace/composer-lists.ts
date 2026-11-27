// Markdown lists keep going while you write a prompt (`ComposerLists` on the Mac): a new line after `- item` starts with
// `- `, after `- [x] done` with `- [ ] `, after `7. step` with `8. ` (zero padding kept: `07.` → `08.`), and a new line
// after an item you left empty ends the list by removing its marker. Here the field knows the caret, so it works on
// any line, not only at the end. No interface code, so tests use it on its own.

const TASK = /^([ \t]*)-[ \t]\[[ xX]\][ \t]+/;
const ORDERED = /^([ \t]*)(\d{1,9})([.)])[ \t]+/;
const BULLET = /^([ \t]*)([-*+])[ \t]+/;

function nextMarker(line: string): { marker: string; length: number } | null {
  let m = TASK.exec(line);
  if (m) return { marker: `${m[1]}- [ ] `, length: m[0].length };
  m = ORDERED.exec(line);
  if (m) {
    const [, indent, number, delimiter] = m;
    let following = String(Number(number) + 1);
    if (number.startsWith("0") && following.length < number.length) following = following.padStart(number.length, "0");
    return { marker: `${indent}${following}${delimiter} `, length: m[0].length };
  }
  m = BULLET.exec(line);
  if (m) return { marker: `${m[1]}${m[2]} `, length: m[0].length };
  return null;
}

/** The draft after a line break was typed just before `caret` (so `text[caret - 1]` is that break), and where the caret
 * goes; null to leave it as it is. */
export function continued(text: string, caret: number): { text: string; caret: number } | null {
  if (caret < 1 || text[caret - 1] !== "\n") return null;
  const start = text.lastIndexOf("\n", caret - 2) + 1;
  const line = text.slice(start, caret - 1);
  const found = nextMarker(line);
  if (!found) return null;
  if (!line.slice(found.length).trim()) {
    // An empty item: the list ends, and its line is left empty.
    const before = text.slice(0, start);
    return { text: before + text.slice(caret), caret: before.length };
  }
  return { text: text.slice(0, caret) + found.marker + text.slice(caret), caret: caret + found.marker.length };
}
