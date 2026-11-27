// Pure helpers for multi-project session labels (`SessionProjects`, #1549) and project source parsing
// (`AddProjectSource`, #1482) — part of AG-113.

/** Turns a browser page URL (`https://github.com/owner/repo/pull/12`) into its repository clone URL. */
export function repositoryUrlFromPage(raw: string): string {
  const trimmed = raw.trim();
  if (!trimmed) return "";
  if (trimmed.startsWith("git@") || trimmed.startsWith("ssh://")) return trimmed;
  try {
    const parsed = new URL(trimmed);
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return trimmed;
    const host = parsed.hostname.toLowerCase();
    const segs = parsed.pathname.split("/").filter(Boolean);
    if (segs.length >= 2) {
      // GitHub / Bitbucket / Gitea / Forgejo: owner/repo[/pull/N|tree/...]
      if (
        host === "github.com" ||
        host.endsWith(".github.com") ||
        host === "bitbucket.org" ||
        host === "codeberg.org"
      ) {
        const repo = segs[1].replace(/\.git$/i, "");
        return `${parsed.origin}/${segs[0]}/${repo}.git`;
      }
      // GitLab: group[/sub]/repo/-/...
      const dashIdx = segs.indexOf("-");
      if (host === "gitlab.com" || host.includes("gitlab")) {
        const repoSegs = dashIdx >= 2 ? segs.slice(0, dashIdx) : segs;
        const last = repoSegs[repoSegs.length - 1].replace(/\.git$/i, "");
        return `${parsed.origin}/${[...repoSegs.slice(0, -1), last].join("/")}.git`;
      }
    }
    return trimmed;
  } catch {
    return trimmed;
  }
}

/** Parses `"owner/repo"`, `"github.com/owner/repo"`, or a GitHub URL into `"https://github.com/owner/repo.git"`. */
export function githubCloneUrl(typed: string): string | null {
  let text = typed.trim();
  if (!text) return null;
  if (text.startsWith("https://") || text.startsWith("git@")) {
    const url = repositoryUrlFromPage(text);
    return url.toLowerCase().includes("github.com") ? url : null;
  }
  for (const prefix of ["http://", "www.", "github.com/"]) {
    if (text.toLowerCase().startsWith(prefix)) {
      text = text.slice(prefix.length);
    }
  }
  if (text.endsWith(".git")) text = text.slice(0, -4);
  text = text.replace(/\/+$/, "");
  const parts = text.split("/");
  if (parts.length !== 2) return null;
  const ok = (p: string) => p.length > 0 && !p.startsWith(".") && /^[A-Za-z0-9._-]+$/.test(p);
  if (!parts.every(ok)) return null;
  return `https://github.com/${parts[0]}/${parts[1]}.git`;
}

/** True when `url` looks like a clonable Git URL (`https://`, `http://`, `ssh://`, or `git@host:owner/repo`). */
export function isValidCloneUrl(url: string): boolean {
  const t = url.trim();
  if (!t || /\s/.test(t)) return false;
  if (/^git@[^:\s]+:[^/\s][^:\s]*$/.test(t)) return true;
  try {
    const u = new URL(t);
    if (!["https:", "http:", "ssh:"].includes(u.protocol)) return false;
    const segs = u.pathname.split("/").filter(Boolean);
    return !!u.hostname && segs.length >= 2;
  } catch {
    return false;
  }
}

/** Cleans a typed project name into a safe single folder name (matching macOS `AddProjectPalette.name`). */
export function sanitizeProjectName(typed: string): string {
  return typed
    .trim()
    .replace(/[/\\:]/g, "-")
    .replace(/^\.+|\.+$/g, "")
    .trim();
}

function leafName(path: string): string {
  const cleaned = path.replace(/[\\/]+$/, "");
  const idx = Math.max(cleaned.lastIndexOf("/"), cleaned.lastIndexOf("\\"));
  return idx >= 0 ? cleaned.slice(idx + 1) : cleaned;
}

/** Deduplicated names of additional projects a session touched, excluding the session's own project name. */
export function multiProjectNames(otherPaths: string[] | undefined, ownName: string): string[] {
  if (!otherPaths?.length) return [];
  const seen = new Set<string>([ownName]);
  const out: string[] = [];
  for (const p of otherPaths) {
    const name = leafName(p).trim();
    if (name && !seen.has(name)) {
      seen.add(name);
      out.push(name);
    }
  }
  return out;
}

/** Formats `"Nook + monorepo"` or `"Nook + monorepo +2"` (`SessionProjects.label` on macOS, #1549). */
export function multiProjectLabel(ownName: string, otherPaths: string[] | undefined, shown = 1): string {
  const others = multiProjectNames(otherPaths, ownName);
  if (!others.length || shown <= 0) return ownName;
  const named = others.slice(0, shown).join(" + ");
  const rest = others.length - shown;
  return rest > 0 ? `${ownName} + ${named} +${rest}` : `${ownName} + ${named}`;
}
