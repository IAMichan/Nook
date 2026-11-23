// The versions of a file while it is open in the side panel (`ArtifactHistory` on the Mac): each time its text changes
// (the agent wrote it again, you saved it) the new text is a version. The panel lists them, shows the difference between
// two as a diff, and restores an older one. No interface code, so tests use it on their own.

export interface ArtifactVersion { number: number; date: number; text: string }

/** The versions kept: the oldest go first when a file is rewritten more often than this. */
export const HISTORY_LIMIT = 30;
/** Larger files are left out: thirty copies of one would weigh more than the panel is worth. */
export const LARGEST_HISTORY_TEXT = 512 * 1024;
/** How many files keep their versions. */
const FILES = 12;

export class ArtifactHistory {
  versions: ArtifactVersion[] = [];
  private counter = 0;

  get latest(): ArtifactVersion | undefined { return this.versions[this.versions.length - 1]; }

  /** Makes `text` a version when it differs from the latest one. True when it is new. The first text seen is version 1. */
  record(text: string, date = Date.now()): boolean {
    if (this.latest?.text === text) return false;
    this.counter += 1;
    this.versions.push({ number: this.counter, date, text });
    if (this.versions.length > HISTORY_LIMIT) this.versions.splice(0, this.versions.length - HISTORY_LIMIT);
    return true;
  }

  version(number: number): ArtifactVersion | undefined { return this.versions.find((v) => v.number === number); }

  /** The version before `number`, as the panel compares one with: undefined for the oldest kept. */
  previous(number: number): ArtifactVersion | undefined {
    const i = this.versions.findIndex((v) => v.number === number);
    return i > 0 ? this.versions[i - 1] : undefined;
  }
}

type Op = { op: "same" | "add" | "remove"; line: string };

const lines = (text: string) => {
  const out = text.replace(/\r\n/g, "\n").split("\n");
  if (out.length > 1 && out[out.length - 1] === "") out.pop();
  return text === "" ? [] : out;
};

/** A line diff: the common start and end are cut off, the rest is matched by the longest common run of lines. A middle
 *  too large to match is shown as all removed, then all added. */
export function lineDiff(a: string[], b: string[]): Op[] {
  let start = 0;
  while (start < a.length && start < b.length && a[start] === b[start]) start += 1;
  let endA = a.length;
  let endB = b.length;
  while (endA > start && endB > start && a[endA - 1] === b[endB - 1]) { endA -= 1; endB -= 1; }
  const out: Op[] = a.slice(0, start).map((line) => ({ op: "same", line }));
  const x = a.slice(start, endA);
  const y = b.slice(start, endB);
  if (x.length * y.length > 4_000_000) {
    out.push(...x.map((line): Op => ({ op: "remove", line })), ...y.map((line): Op => ({ op: "add", line })));
  } else {
    const w = y.length + 1;
    const t = new Uint32Array((x.length + 1) * w);
    for (let i = x.length - 1; i >= 0; i -= 1) {
      for (let j = y.length - 1; j >= 0; j -= 1) t[i * w + j] = x[i] === y[j] ? t[(i + 1) * w + j + 1] + 1 : Math.max(t[(i + 1) * w + j], t[i * w + j + 1]);
    }
    let i = 0;
    let j = 0;
    while (i < x.length && j < y.length) {
      if (x[i] === y[j]) { out.push({ op: "same", line: x[i] }); i += 1; j += 1; }
      else if (t[(i + 1) * w + j] >= t[i * w + j + 1]) { out.push({ op: "remove", line: x[i] }); i += 1; }
      else { out.push({ op: "add", line: y[j] }); j += 1; }
    }
    for (; i < x.length; i += 1) out.push({ op: "remove", line: x[i] });
    for (; j < y.length; j += 1) out.push({ op: "add", line: y[j] });
  }
  out.push(...a.slice(endA).map((line): Op => ({ op: "same", line })));
  return out;
}

/** The lines added and removed from `old` to `next`. */
export function lineCounts(old: string, next: string): { added: number; removed: number } {
  const ops = lineDiff(lines(old), lines(next));
  return { added: ops.filter((o) => o.op === "add").length, removed: ops.filter((o) => o.op === "remove").length };
}

/** The change from `old` to `next` as a unified diff of `name` (three lines of context), which the diff viewer draws like
 *  any other. Empty when the texts are the same. */
export function unifiedDiff(old: string, next: string, name: string, context = 3): string {
  const ops = lineDiff(lines(old), lines(next));
  const changed = ops.flatMap((o, i) => (o.op === "same" ? [] : [i]));
  if (!changed.length) return "";
  const groups: { first: number; last: number }[] = [];
  for (const i of changed) {
    const g = groups[groups.length - 1];
    if (g && i - g.last <= 2 * context + 1) g.last = i;
    else groups.push({ first: i, last: i });
  }
  const out = [`diff --git a/${name} b/${name}`, `--- a/${name}`, `+++ b/${name}`];
  for (const g of groups) {
    const start = Math.max(0, g.first - context);
    const end = Math.min(ops.length - 1, g.last + context);
    let oldBefore = 0;
    let newBefore = 0;
    for (const o of ops.slice(0, start)) {
      if (o.op !== "add") oldBefore += 1;
      if (o.op !== "remove") newBefore += 1;
    }
    let oldCount = 0;
    let newCount = 0;
    const body: string[] = [];
    for (const o of ops.slice(start, end + 1)) {
      if (o.op === "same") { oldCount += 1; newCount += 1; body.push(" " + o.line); }
      else if (o.op === "remove") { oldCount += 1; body.push("-" + o.line); }
      else { newCount += 1; body.push("+" + o.line); }
    }
    // A side with no lines names the line before the change, as git does.
    out.push(`@@ -${oldCount === 0 ? oldBefore : oldBefore + 1},${oldCount} +${newCount === 0 ? newBefore : newBefore + 1},${newCount} @@`, ...body);
  }
  return out.join("\n") + "\n";
}

const histories = new Map<string, ArtifactHistory>();
const order: string[] = [];

/** The versions of a file kept so far (an empty history for a file not seen). */
export const historyOf = (path: string): ArtifactHistory => histories.get(path) ?? new ArtifactHistory();

/** Makes `text` the latest version of the file when it differs from the one before; true when it did. */
export function recordVersion(path: string, text: string): boolean {
  if (text.length > LARGEST_HISTORY_TEXT) return false;
  const h = histories.get(path) ?? new ArtifactHistory();
  if (!h.record(text)) return false;
  histories.set(path, h);
  const at = order.indexOf(path);
  if (at >= 0) order.splice(at, 1);
  order.push(path);
  while (order.length > FILES) histories.delete(order.shift()!);
  return true;
}
