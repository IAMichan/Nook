// Session pull-request mention extraction (`PullRequestMentions` on macOS, AG-123):
// extracts PRs referenced in CLI commands (`gh pr ...`, `glab mr ...`), user messages (`#123`, URLs),
// and timeline events so the session's Pull Requests side panel highlights them.
import type { AccountPullRequests, PullRequestItem } from "../connectors";
import type { RunEvent } from "./api";

export interface SessionPrMention {
  repo: string | null;
  number: number;
  url: string | null;
}

const PR_COMMAND_RE =
  /(?:^|[\s;&|(`"'])(?:gh\s+pr|glab\s+mr)\s+(?:checkout|co|view|show|checks|diff|edit|comment|note|merge|ready|review|approve|close|reopen|update-branch|rebase)\b([^;&|\n`)]*)/gi;

const URL_RE = /https?:\/\/[^\s<>()[\]"'`]+/gi;
const HASH_NUMBER_RE = /(^|[^\w#/&])#(\d{1,7})\b/g;

const VALUE_FLAGS = new Set([
  "-b", "--body", "-F", "--body-file", "-t", "--title", "-m", "--message", "--subject",
  "-q", "--jq", "--json", "--template", "-B", "--base", "--branch", "--add-label",
  "--remove-label", "--add-reviewer", "--remove-reviewer", "--add-assignee", "--remove-assignee",
  "--milestone", "-i", "--interval", "--match-head-commit", "--author-email", "-A",
  "--assignee", "-l", "--label", "--reviewer", "--target-branch", "--source-branch", "--description",
]);

/** Parses a GitHub PR or GitLab MR URL into `{ repo, number, url }`. */
export function parsePrUrl(raw: string): SessionPrMention | null {
  try {
    const u = new URL(raw.trim().replace(/[.,;:!?]+$/, ""));
    if (u.protocol !== "https:" && u.protocol !== "http:") return null;
    const host = u.hostname.toLowerCase();
    const segs = u.pathname.split("/").filter(Boolean);
    if ((host === "github.com" || host === "www.github.com") && segs.length >= 4 && segs[2] === "pull") {
      const num = Number.parseInt(segs[3], 10);
      if (num > 0) {
        const repo = `${segs[0]}/${segs[1]}`;
        return { repo, number: num, url: `https://github.com/${repo}/pull/${num}` };
      }
    }
    const dash = segs.indexOf("-");
    if (dash >= 2 && segs[dash + 1] === "merge_requests" && segs[dash + 2]) {
      const num = Number.parseInt(segs[dash + 2], 10);
      if (num > 0) {
        const repo = segs.slice(0, dash).join("/");
        return { repo, number: num, url: `https://${host}/${repo}/-/merge_requests/${num}` };
      }
    }
  } catch {
    // Not a valid URL.
  }
  return null;
}

function parseCommandArgs(args: string): SessionPrMention | null {
  const words = args
    .trim()
    .split(/\s+/)
    .map((w) => w.replace(/^["']|["']$/g, ""))
    .filter(Boolean);
  let repo: string | null = null;
  let number: number | null = null;
  let linked: SessionPrMention | null = null;
  for (let i = 0; i < words.length; i++) {
    const w = words[i];
    if (w === "-R" || w === "--repo") {
      if (i + 1 < words.length) repo = words[i + 1];
      i += 1;
      continue;
    }
    if (w.startsWith("--repo=")) {
      repo = w.slice("--repo=".length);
    } else if (w.startsWith("-")) {
      if (VALUE_FLAGS.has(w)) i += 1;
    } else if (number === null && linked === null) {
      if (w.includes("://")) {
        linked = parsePrUrl(w);
      } else {
        const clean = w.startsWith("#") ? w.slice(1) : w;
        if (/^\d{1,7}$/.test(clean)) {
          const n = Number.parseInt(clean, 10);
          if (n > 0) number = n;
        }
      }
    }
  }
  if (linked) return linked;
  if (number === null) return null;
  const cleanRepo = repo && repo.includes("/") && !repo.includes("://") ? repo : null;
  return { repo: cleanRepo, number, url: null };
}

function dedupe(items: SessionPrMention[]): SessionPrMention[] {
  const seen = new Set<string>();
  return items.filter((m) => {
    const key = (m.url ?? (m.repo ? `${m.repo}#${m.number}` : `#${m.number}`)).toLowerCase();
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

/** Extracts pull requests mentioned across a session's timeline (CLI commands, user `#123`/URLs, and PR links). */
export function prMentionsInEvents(events: readonly RunEvent[]): SessionPrMention[] {
  const out: SessionPrMention[] = [];
  for (const e of events) {
    if (e.rolledBack) continue;
    const sources: string[] = [e.text];
    if (e.output) sources.push(e.output);
    if (e.kind === "tool" && e.detail) {
      try {
        const parsed = JSON.parse(e.detail) as Record<string, unknown>;
        for (const k of ["command", "CommandLine", "cmd", "script"]) {
          if (typeof parsed[k] === "string") sources.push(parsed[k]);
        }
      } catch {
        sources.push(e.detail);
      }
    }
    for (const src of sources) {
      for (const m of src.matchAll(URL_RE)) {
        const pr = parsePrUrl(m[0]);
        if (pr) out.push(pr);
      }
      if (e.kind === "tool") {
        for (const m of src.matchAll(PR_COMMAND_RE)) {
          const target = parseCommandArgs(m[1] ?? "");
          if (target) out.push(target);
        }
      }
    }
    if (e.kind === "user") {
      for (const m of e.text.matchAll(HASH_NUMBER_RE)) {
        const n = Number.parseInt(m[2], 10);
        if (n > 0) out.push({ repo: null, number: n, url: null });
      }
    }
  }
  return dedupe(out);
}

/** Matches session PR mentions against loaded account PR items, keeping each matched PR once. */
export function matchedMentionedPullRequests(
  mentions: readonly SessionPrMention[],
  accounts: readonly AccountPullRequests[],
): { accountId: string; item: PullRequestItem }[] {
  if (!mentions.length) return [];
  const all: { accountId: string; item: PullRequestItem }[] = [];
  const seen = new Set<string>();
  for (const acc of accounts) {
    for (const item of [...acc.reviews, ...acc.mine, ...acc.watched]) {
      const id = `${item.repo.toLowerCase()}#${item.number}`;
      if (seen.has(id)) continue;
      const matches = mentions.some((m) => {
        if (m.number !== item.number) return false;
        return !m.repo || m.repo.toLowerCase() === item.repo.toLowerCase();
      });
      if (matches) {
        seen.add(id);
        all.push({ accountId: acc.id, item });
      }
    }
  }
  return all;
}
