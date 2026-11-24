// A file an agent pointed at (`FileLinks` on the Mac): `src/app.ts:12:3`, `src/app.ts:42-64`, `./README.md`, `~/notes.txt`,
// `C:\work\a.ts:7`, `/abs/path.ts#L12`, `/abs/path.ts#L42-L64`, or `file:///abs/path.ts`. Opening one puts the file
// viewer on that line. Pure functions, so they are tested on their own.

export interface FileTarget {
  path: string;
  line?: number;
  column?: number;
  /** The last line of a range (`app.ts:42-64`, `#L42-L64`); the file opens at `line`, the first. */
  endLine?: number;
}

const POSITION = /^(.+?):(\d+)(?::(\d+))?(?:-(\d+))?$/;
const GITHUB_ANCHOR = /#L(\d+)(?:C(\d+))?(?:-L?(\d+)(?:C\d+)?)?$/;
const SCHEME = /^([A-Za-z][A-Za-z0-9+.-]*):/;

/** "L42", or "L42–64" for a range: how a link's place reads next to its file. */
export function lineLabel(t: FileTarget): string | null {
  if (!t.line) return null;
  return t.endLine && t.endLine > t.line ? `L${t.line}\u2013${t.endLine}` : `L${t.line}`;
}

/** The file a link or a piece of text points at, or null when it is a web, mail or other link. */
export function parseFileLink(raw: string): FileTarget | null {
  let text = raw.trim();
  if (!text || text.includes("\n")) return null;
  if (text.toLowerCase().startsWith("file://")) {
    let path = text.slice(7);
    // `file:///C:/work/a.ts` carries the drive after a slash.
    if (/^\/[A-Za-z]:/.test(path)) path = path.slice(1);
    text = path;
  } else if (!/^[A-Za-z]:[\\/]/.test(text)) {
    const m = SCHEME.exec(text);
    if (m) {
      // `app.ts:12` reads as the scheme `app.ts`; a real scheme is not followed by a line number.
      const rest = text.slice(m[1].length + 1);
      if (!m[1].includes(".") || !/^\d/.test(rest)) return null;
    }
  }
  try {
    text = decodeURIComponent(text);
  } catch {
    // Keep the text as it is.
  }

  let line: number | undefined;
  let column: number | undefined;
  let endLine: number | undefined;
  const anchor = GITHUB_ANCHOR.exec(text);
  const position = anchor ? null : POSITION.exec(text);
  if (anchor) {
    line = Number(anchor[1]);
    column = anchor[2] ? Number(anchor[2]) : undefined;
    endLine = anchor[3] ? Number(anchor[3]) : undefined;
    text = text.slice(0, anchor.index);
  } else if (position && !/^[A-Za-z]$/.test(position[1])) {
    line = Number(position[2]);
    column = position[3] ? Number(position[3]) : undefined;
    endLine = position[4] ? Number(position[4]) : undefined;
    text = position[1];
  }
  if (!text || text.startsWith("#") || text.startsWith("?")) return null;
  if (line !== undefined && line < 1) return null;
  return {
    path: text,
    line,
    column: column !== undefined && column >= 1 ? column : undefined,
    // A range runs forward; `:64-42` or `:42-42` is just its first line.
    endLine: endLine !== undefined && line !== undefined && endLine > line ? endLine : undefined,
  };
}

const FILE_EXTENSIONS = new Set([
  "md", "markdown", "mdx", "txt", "rtf", "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers",
  "csv", "tsv", "json", "jsonl", "yml", "yaml", "toml", "xml", "plist", "ini", "conf", "env", "log", "lock",
  "html", "htm", "css", "scss", "svg", "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "ico",
  "mp4", "mov", "m4v", "webm", "mp3", "wav", "m4a", "zip", "ipynb", "sql", "mmd", "mermaid",
  "swift", "js", "jsx", "mjs", "cjs", "ts", "tsx", "vue", "svelte", "py", "rb", "go", "rs", "java", "kt", "kts",
  "c", "h", "cc", "cpp", "hpp", "m", "mm", "cs", "php", "sh", "bash", "zsh", "fish", "gradle", "ps1", "bat", "cmd",
]);
/** Endings of web addresses that are no file extension (`docs.example.com/guide.io`). */
const DOMAIN_ENDINGS = new Set(["com", "net", "org", "io", "nl", "de", "fr", "es", "be", "uk", "app", "dev"]);

/** The file a code span names on its own (`banner.png`, `src/app.ts:12`, `~/notes.md`), so an answer that lists the
 *  files it made can open them. A name needs an extension Nook knows, or a folder before it; a type
 *  (`AppModel.shared`), a domain (`example.com`) or a route (`/api/users`) is no file. */
export function namedFile(code: string): FileTarget | null {
  const text = code.trim();
  if (!text || text.length > 300 || /\s/.test(text) || text.includes("://") || /[\\/]$/.test(text)) return null;
  const target = parseFileLink(text);
  if (!target) return null;
  const name = target.path.split(/[\\/]/).pop() ?? "";
  const dot = name.lastIndexOf(".");
  const ext = dot >= 0 ? name.slice(dot + 1).toLowerCase() : "";
  if (!ext || !/^[a-z]/.test(ext) || ext.length > 10 || name.length <= ext.length + 1) return null;
  const folder = /[\\/]/.test(target.path);
  if (!FILE_EXTENSIONS.has(ext) && !(folder && !DOMAIN_ENDINGS.has(ext))) return null;
  return target;
}

const isAbsolute = (p: string) => p.startsWith("/") || /^[A-Za-z]:[\\/]/.test(p) || p.startsWith("\\\\");

/** The target with an absolute path: `~` is your home folder, a relative path is read from `base` (the session's
 *  folder). Null for a relative path without a base. `.` and `..` parts are folded away. */
export function resolveFileTarget(target: FileTarget, base: string | null | undefined, home = ""): FileTarget | null {
  let path = target.path;
  if (path === "~" || path.startsWith("~/") || path.startsWith("~\\")) {
    if (!home) return null;
    path = home.replace(/[\\/]+$/, "") + path.slice(1);
  } else if (!isAbsolute(path)) {
    if (!base) return null;
    path = base.replace(/[\\/]+$/, "") + "/" + path;
  }
  return { ...target, path: normalizePath(path) };
}

/** Folds `.` and `..` away and keeps the separator style of the path. */
export function normalizePath(path: string): string {
  const sep = path.includes("\\") && !path.includes("/") ? "\\" : "/";
  const parts = path.split(/[\\/]/);
  const root = parts[0] === "" ? "" : /^[A-Za-z]:$/.test(parts[0]) ? parts[0] : null;
  const out: string[] = [];
  for (const part of root === null ? parts : parts.slice(1)) {
    if (part === "" || part === ".") continue;
    if (part === "..") out.pop();
    else out.push(part);
  }
  return (root ?? "") + sep + out.join(sep);
}

/** The path as the user's folder shows it, for a title (`~/…` when inside home). */
export const fileName = (path: string) => path.replace(/[\\/]+$/, "").split(/[\\/]/).pop() ?? path;

/** A file link clicked in the conversation: `{ raw, base }` (the link's text and the session's folder). */
export const OPEN_FILE_EVENT = "nook-open-file";
