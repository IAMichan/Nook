// The sources card under an answer: per source what happened (found, nothing found, sent as context, not read,
// searching), in the order that needs attention first. Pure logic, so it can be tested without a component.
import type { RetrievalStep } from "./brain";
import type { ChatMessage, SourceReference } from "./types";
import { tr } from "./i18n.svelte";

export type SourceStatus = "found" | "empty" | "failed" | "running" | "context";

export interface SourceGroup {
  title: string;
  sourceId: string | null;
  status: SourceStatus;
  /** Why the source could not be read (only for `failed`). */
  reason: string;
  queries: string[];
  references: SourceReference[];
}

/** The text Rust stores for a search that was still running when the answer stopped (`retrieval::INTERRUPTED`). */
const RUST_INTERRUPTED = "Het zoeken werd onderbroken voordat het klaar was.";
/** Shown for a search that was still running when the answer stopped. */
export const interrupted = () => tr("Het zoeken werd onderbroken voordat het klaar was.", "The search was interrupted before it finished.");
/** Shown when an error said nothing a person can use. */
export const unknownError = () => tr("Er ging iets mis bij het lezen.", "Something went wrong while reading.");

/** Older stored answers kept the raw error; show those the way new answers do. */
export function readableFailure(reason: string): string {
  const text = reason.trim();
  const lower = text.toLowerCase();
  if (text === RUST_INTERRUPTED || lower.includes("cancellationerror") || lower === "gestopt" || lower.includes("cancelled")) return interrupted();
  if (!text || lower.includes("couldn’t be completed") || lower.includes("couldn't be completed")) return unknownError();
  return text;
}

const rank: Record<SourceStatus, number> = { failed: 0, running: 1, found: 2, context: 3, empty: 4 };

/** Groups the retrieval of an answer per source; sources that need attention first, then what was used, then the rest. */
export function sourceGroups(message: ChatMessage, streaming: boolean): SourceGroup[] {
  const result: SourceGroup[] = [];
  const get = (title: string, sourceId: string | null = null) => {
    let g = result.find((x) => x.title === title);
    if (!g) {
      g = { title, sourceId, status: "context", reason: "", queries: [], references: [] };
      result.push(g);
    }
    if (!g.sourceId && sourceId) g.sourceId = sourceId;
    return g;
  };
  const byTitle = new Map<string, RetrievalStep[]>();
  for (const step of message.retrieval ?? []) byTitle.set(step.sourceTitle, [...(byTitle.get(step.sourceTitle) ?? []), step]);
  for (const [title, steps] of byTitle) {
    const g = get(title, steps.find((s) => s.sourceId)?.sourceId ?? null);
    g.queries = steps.map((s) => s.query).filter(Boolean);
    const failed = steps.find((s) => s.outcome.kind === "failed");
    if (steps.some((s) => s.outcome.kind === "running")) {
      // A search still marked as running after the answer finished was interrupted, not searching forever.
      if (streaming) g.status = "running";
      else {
        g.status = "failed";
        g.reason = interrupted();
      }
    } else if (!steps.some((s) => s.outcome.kind === "found") && failed) {
      g.status = "failed";
      g.reason = readableFailure(failed.outcome.kind === "failed" ? failed.outcome.detail : "");
    } else if (steps.every((s) => s.outcome.kind === "empty")) g.status = "empty";
    else g.status = "found";
  }
  for (const ref of message.references ?? []) {
    const step = (message.retrieval ?? []).find((s) => s.sourceId === ref.sourceId);
    get(step?.sourceTitle ?? ref.sourceId ?? tr("Bron", "Source"), ref.sourceId).references.push(ref);
  }
  for (const source of [...(message.sources ?? []), ...(message.contextSources ?? [])]) get(source);
  return result.map((g, i) => [g, i] as const).sort((a, b) => rank[a[0].status] - rank[b[0].status] || a[1] - b[1]).map(([g]) => g);
}

/** Every source says how it went: found (and how much), nothing found, sent as context, not read, or still searching. */
export function statusText(group: SourceGroup): string {
  switch (group.status) {
    case "found": {
      const count = group.references.length;
      if (count === 0) return tr("Gevonden", "Found");
      return count === 1 ? tr("1 resultaat", "1 result") : tr("{n} resultaten", "{n} results", { n: count });
    }
    case "context": return tr("Meegestuurd als context", "Sent as context");
    case "empty": return tr("Niets gevonden", "Nothing found");
    case "failed": return tr("Niet gelezen", "Not read");
    case "running": return tr("Zoekt…", "Searching…");
  }
}

/** The one line above the list: what was used, or that Nook is still searching. */
export function sourcesSummary(groups: SourceGroup[], streaming: boolean): string {
  if (streaming && groups.some((g) => g.status === "running")) return tr("Zoekt in je bronnen…", "Searching your sources…");
  const used = groups.filter((g) => g.status === "found" || g.status === "context").length;
  if (used === 0) return tr("Niets gevonden", "Nothing found");
  return used === 1 ? tr("Gebruikte 1 bron", "Used 1 source") : tr("Gebruikte {n} bronnen", "Used {n} sources", { n: used });
}

const legacyIncomplete = new Set([
  "Dit antwoord is daardoor mogelijk onvolledig.",
  "This answer may therefore be incomplete.",
]);

/** The warnings to show under the answer. Older answers also repeated every unreadable source as a warning
 *  ("Mail kon niet worden doorzocht: …", "Dit antwoord is daardoor mogelijk onvolledig."); the sources card shows those now. */
export function visibleNotices(message: ChatMessage): string[] {
  const failures = (message.retrieval ?? []).flatMap((s) => (s.outcome.kind === "failed" && s.outcome.detail ? [s.outcome.detail] : []));
  if (!failures.length) return message.notices ?? [];
  return (message.notices ?? []).filter((n) => !legacyIncomplete.has(n) && !failures.some((f) => n.includes(f)));
}

/** The website whose icon stands for a source (the same as `brand::domain` in Rust); none for local sources. */
export function sourceDomain(id: string | null): string | null {
  const domains: Record<string, string> = {
    github: "github.com",
    gitlab: "gitlab.com",
    vercel: "vercel.com",
    stripe: "stripe.com",
    notion: "notion.so",
    calcom: "cal.com",
    n8n: "n8n.io",
    resend: "resend.com",
    whatsapp: "whatsapp.com",
    linear: "linear.app",
    sentry: "sentry.io",
  };
  return (id && domains[id]) || null;
}

/** Localized display title for a source id (`SourceCatalog.title` on macOS). */
export function sourceTitle(id: string | null | undefined): string {
  if (!id) return "";
  switch (id) {
    case "calendar": return tr("Agenda", "Calendar");
    case "icalfeeds": return tr("Andere agenda’s", "Other calendars");
    case "calcom": return "Cal.com";
    case "reminders": return tr("Herinneringen", "Reminders");
    case "notes": return tr("Notities", "Notes");
    case "messages": return tr("Berichten", "Messages");
    case "whatsapp": return "WhatsApp";
    case "bear": return "Bear";
    case "callnotes": return tr("Gesprekken", "Calls");
    case "system": return tr("Dit apparaat", "This computer");
    case "things": return "Things";
    case "loops": return tr("Open punten", "Open items");
    case "memory": return tr("Geheugen", "Memory");
    case "mail": return tr("Mail", "Mail");
    case "browser": return "Browser";
    case "terminal": return "Terminal";
    case "files": return tr("Bestanden", "Files");
    case "contacts": return tr("Contacten", "Contacts");
    case "clipboard": return tr("Klembord", "Clipboard");
    case "screen": return tr("Scherm", "Screen");
    case "github": return "GitHub";
    case "gitlab": return "GitLab";
    case "vercel": return "Vercel";
    case "stripe": return "Stripe";
    case "notion": return "Notion";
    case "n8n": return "n8n";
    case "resend": return "Resend";
    case "linear": return "Linear";
    case "sentry": return "Sentry";
    case "customsources": return tr("Eigen bronnen", "Custom sources");
    case "web": return "Web";
    default: return id;
  }
}
