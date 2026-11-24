// What you point an agent at from the composer (`ContextRef`, `ContextRefs` and `ComposerAttachments` in the Mac's
// ComposerCore.swift): a file, a folder, a picture, another session or a pull request. In the draft each sits as a link
// that reads well; the agent gets a short marker in place (`@Login.swift`) and one `<nook_context>` envelope after the
// text with a record per reference, so a path never grants anything and a long session is not pasted. Pictures follow
// the envelope as paths on lines of their own. No interface code, so tests use it on its own.

export type RefKind = "file" | "session" | "pullRequest" | "skill" | "model";

export interface ContextRef {
  kind: RefKind;
  /** A path, a session id, "owner/repo#12", a skill's or model's name. */
  id: string;
  label: string;
}

const SCHEME = "nook-context";
const VERSION = "v1";
const PATTERN = /\[([^\]\n]*)\]\(nook-context:\/\/v1\/([a-zA-Z]+)\/([^)\s]*)\)/g;

/** `[Login.swift](nook-context://v1/file/Sources%2FLogin.swift)` */
export function link(ref: ContextRef): string {
  const id = encodeURIComponent(ref.id).replace(/%2F/gi, "/");
  const label = ref.label.replace(/\[/g, "(").replace(/\]/g, ")");
  return `[${label}](${SCHEME}://${VERSION}/${ref.kind}/${id})`;
}

export interface Found extends ContextRef {
  start: number;
  end: number;
}

/** The references in a text, in order. */
export function find(text: string): Found[] {
  const out: Found[] = [];
  for (const m of text.matchAll(PATTERN)) {
    const kind = m[2] as RefKind;
    if (!["file", "session", "pullRequest", "skill", "model"].includes(kind)) continue;
    let id = m[3];
    try { id = decodeURIComponent(id); } catch { /* kept as written */ }
    out.push({ kind, id, label: m[1], start: m.index!, end: m.index! + m[0].length });
  }
  return out;
}

/** `<` and `&` made harmless: an id can never close a record or open another. */
const escape = (text: string) => text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/"/g, "&quot;");

function marker(ref: ContextRef): string {
  switch (ref.kind) {
    case "file": return "@" + ref.label;
    case "session": return `[session: ${ref.label}]`;
    case "pullRequest": return "#" + ref.label;
    case "skill": return "$" + ref.label;
    case "model": return `[model: ${ref.label}]`;
  }
}

/** What the agent receives (`ContextRefs.project`): markers in place, the envelope after the text, then the pictures. */
export function project(text: string, pictures: string[] = []): string {
  const found = find(text);
  let result = text;
  for (const item of [...found].reverse()) result = result.slice(0, item.start) + marker(item) + result.slice(item.end);
  if (found.length) {
    const seen = new Set<string>();
    const records: string[] = [];
    for (const item of found) {
      const key = `${item.kind}|${item.id}`;
      if (seen.has(key)) continue;
      seen.add(key);
      records.push(`<ref kind="${item.kind}" id="${escape(item.id)}"/>`);
    }
    result += "\n\n<nook_context>\n" + records.join("\n") + "\n</nook_context>";
  }
  if (pictures.length) result += (found.length ? "\n" : "\n\n") + pictures.join("\n");
  return result;
}

/** How a picked reference reads in the draft until it goes out. */
export function mentionToken(ref: ContextRef): string {
  return (ref.kind === "pullRequest" ? "#" : ref.kind === "skill" ? "$" : "@") + ref.label;
}

/** The draft as it goes out: the words, the attachments as links on their own line under them (`spaced`). */
export function compose(words: string, attached: ContextRef[], mentions: ContextRef[]): string {
  let body = words;
  // A mention typed as `@label` (`#12` for a pull request, `$name` for a skill) becomes its link where it stands; one
  // you deleted again is gone.
  for (const ref of mentions) {
    const token = mentionToken(ref);
    const at = body.indexOf(token);
    if (at >= 0) body = body.slice(0, at) + link(ref) + body.slice(at + token.length);
  }
  const tail = attached.map(link).join(" ");
  const trimmed = body.trim();
  if (!tail) return trimmed;
  return trimmed ? `${trimmed}\n\n${tail}` : tail;
}

const unescape = (text: string) => text.replace(/&quot;/g, '"').replace(/&lt;/g, "<").replace(/&amp;/g, "&");
const basename = (path: string) => path.replace(/[\\/]+$/, "").split(/[\\/]/).pop() ?? path;
const isAbsolute = (p: string) => p.startsWith("/") || /^[A-Za-z]:[\\/]/.test(p) || p.startsWith("\\\\");

/**
 * What your message shows in the timeline (`ContextRefs.timeline`): the words without the envelope, and the files and
 * folders attached at its end plus the pictures sent with it as paths, for tiles above the bubble. Relative paths start
 * from `folder`.
 */
export function timeline(projected: string, folder?: string | null): { words: string; paths: string[] } {
  const start = projected.indexOf("\n\n<nook_context>\n");
  const end = start >= 0 ? projected.indexOf("\n</nook_context>", start) : -1;
  if (start < 0 || end < 0) {
    // Pictures alone: absolute paths on the last lines.
    const lines = projected.split("\n");
    const paths: string[] = [];
    while (lines.length && isAbsolute(lines[lines.length - 1].trim()) && /\.(png|jpe?g|gif|webp|heic)$/i.test(lines[lines.length - 1].trim())) paths.unshift(lines.pop()!.trim());
    return { words: lines.join("\n").trim(), paths };
  }
  let words = projected.slice(0, start);
  const records = projected.slice(start + "\n\n<nook_context>\n".length, end);
  const pictures = projected.slice(end + "\n</nook_context>".length).split("\n").map((l) => l.trim()).filter(Boolean);
  const files = [...records.matchAll(/^<ref kind="file" id="([^"]*)"\/>$/gm)].map((m) => unescape(m[1]));
  const attached: string[] = [];
  // The attached files close the words, one `@label` after another: take them off from the end.
  for (;;) {
    const trimmed = words.trimEnd();
    let index = -1;
    for (let i = files.length - 1; i >= 0; i--) {
      if (trimmed.endsWith("@" + basename(files[i]).replace(/\[/g, "(").replace(/\]/g, ")"))) { index = i; break; }
    }
    if (index < 0) break;
    const id = files.splice(index, 1)[0];
    words = trimmed.slice(0, trimmed.length - ("@" + basename(id)).length);
    const sep = folder && folder.includes("\\") ? "\\" : "/";
    attached.unshift(isAbsolute(id) || !folder ? id : `${folder.replace(/[\\/]+$/, "")}${sep}${id}`);
  }
  return { words: words.trim(), paths: [...attached, ...pictures] };
}

/** A file or folder you attach by its path: labeled by its name. */
export function fileRef(path: string): ContextRef {
  return { kind: "file", id: path, label: basename(path) || path };
}

export const isPicture = (path: string) => /\.(png|jpe?g|gif|webp|heic|bmp)$/i.test(path);
