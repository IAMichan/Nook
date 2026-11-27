// Pure source-control helpers matching `SourceControl.swift` and `PublishRepositorySheet.swift` (AG-120).

export type SubmodulesMode = "recursive" | "topLevel" | "skip";

export interface PublishPlan {
  folder: string;
  name: string;
  needsRepository: boolean;
  needsFirstCommit: boolean;
}

/** GitHub repository name rule: ASCII letters, digits, '.', '-', '_', 1..=100 chars, not "." or "..". */
export function isValidRepositoryName(name: string): boolean {
  if (!name || name.length > 100 || name === "." || name === "..") return false;
  return /^[A-Za-z0-9._-]+$/.test(name);
}

/** Suggests a valid GitHub repository name from a folder name: "My App (2)" -> "My-App-2". */
export function suggestedRepositoryName(folder: string): string {
  let result = "";
  let lastDash = false;
  for (const ch of folder) {
    if (/[A-Za-z0-9._]/.test(ch)) {
      result += ch;
      lastDash = false;
    } else if (!lastDash && result.length > 0) {
      result += "-";
      lastDash = true;
    }
  }
  result = result.replace(/[-.]+$/, "").slice(0, 100);
  return isValidRepositoryName(result) ? result : "project";
}

/** 7..=40 lowercase hex characters containing at least one digit and one letter. */
export function isCommitHash(text: string): boolean {
  if (text.length < 7 || text.length > 40) return false;
  if (!/^[0-9a-f]+$/.test(text)) return false;
  return /[0-9]/.test(text) && /[a-f]/.test(text);
}

/** Extracts a commit hash from `nook-commit:<hash>` or a GitHub commit URL. */
export function commitHashInUrl(raw: string): string | null {
  const trimmed = raw.trim();
  if (trimmed.startsWith("nook-commit:")) {
    const rest = trimmed.slice("nook-commit:".length).replace(/^\/+|\/+$/g, "");
    return isCommitHash(rest) ? rest : null;
  }
  try {
    const url = new URL(trimmed);
    if (url.protocol !== "https:" || url.hostname.toLowerCase() !== "github.com") return null;
    const parts = url.pathname.split("/").filter(Boolean);
    if (parts.length >= 4 && parts[2] === "commit") {
      const h = parts[3].toLowerCase();
      return isCommitHash(h) ? h : null;
    }
    if (parts.length >= 6 && parts[2] === "pull" && parts[4] === "commits") {
      const h = parts[5].toLowerCase();
      return isCommitHash(h) ? h : null;
    }
    return null;
  } catch {
    return null;
  }
}
