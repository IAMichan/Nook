// Helpers for custom ACP agents (`CustomAgents`, `AcpRegistry`, AG-21).
import type { CustomAgent, RegistryEntry } from "./api";

export interface ParsedCommand {
  command: string;
  arguments: string[];
}

/**
 * Splits a typed command line (`npx -y @vendor/agent-acp@1.0.0`) with shell-style quotes.
 * Returns `null` when empty, when a quote is left open, or when it ends on a bare backslash.
 */
export function parseAcpCommand(line: string): ParsedCommand | null {
  const parts: string[] = [];
  let current = "";
  let quote: '"' | "'" | null = null;
  let hasToken = false;
  let escaped = false;

  for (const ch of line) {
    if (escaped) {
      current += ch;
      escaped = false;
      hasToken = true;
      continue;
    }
    if (ch === "\\" && quote !== "'") {
      escaped = true;
      continue;
    }
    if (quote !== null) {
      if (ch === quote) {
        quote = null;
      } else {
        current += ch;
      }
      continue;
    }
    if (ch === '"' || ch === "'") {
      quote = ch;
      hasToken = true;
      continue;
    }
    if (/\s/.test(ch)) {
      if (hasToken) {
        parts.push(current);
        current = "";
        hasToken = false;
      }
      continue;
    }
    current += ch;
    hasToken = true;
  }

  if (quote !== null || escaped) return null;
  if (hasToken) parts.push(current);
  if (parts.length === 0 || parts[0].length === 0) return null;
  return { command: parts[0], arguments: parts.slice(1) };
}

/** Full human-readable command line for display in Settings. */
export function formatCommandLine(agent: Pick<CustomAgent, "command" | "arguments">): string {
  return [agent.command, ...agent.arguments].join(" ");
}

/** Filters and sorts ACP registry entries: supported entries first, then alphabetical by name. */
export function filterAndSortRegistry(entries: RegistryEntry[], query: string): RegistryEntry[] {
  const needle = query.trim().toLowerCase();
  const filtered = needle
    ? entries.filter(
        (e) =>
          e.name.toLowerCase().includes(needle) ||
          e.id.toLowerCase().includes(needle) ||
          e.description.toLowerCase().includes(needle),
      )
    : entries.slice();
  return filtered.sort((a, b) => {
    const sa = a.supported ? 0 : 1;
    const sb = b.supported ? 0 : 1;
    if (sa !== sb) return sa - sb;
    return a.name.toLowerCase().localeCompare(b.name.toLowerCase());
  });
}

/** First 12 hex characters of a SHA-256 digest with an ellipsis, matching macOS. */
export function shortSha256(sha256: string): string {
  return sha256.length > 12 ? `${sha256.slice(0, 12)}…` : sha256;
}
