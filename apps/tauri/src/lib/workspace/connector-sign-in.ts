// Pure helpers for MCP connector sign-ins above the session composer and in the session menu (`ConnectorSignIns`, AG-31).
import type { ConnectorSignIn } from "./api";

/** Maximum number of connector logos shown side by side in the banner (`ConnectorLogos.limit` on the Mac). */
export const BANNER_LOGO_LIMIT = 3;

/** Up to this many connectors show directly in the session menu; more fold into a disclosure row (`ConnectorSignInGroup.inlineLimit`). */
export const MENU_INLINE_LIMIT = 3;

/** Connectors shown in the banner above the composer: waiting ones stay visible even if dismissed. */
export function shownConnectors(all: readonly ConnectorSignIn[], dismissed: ReadonlySet<string> | readonly string[]): ConnectorSignIn[] {
  const hidden = dismissed instanceof Set ? dismissed : new Set(dismissed);
  return all.filter((c) => c.waiting || !hidden.has(c.name));
}

/** First connector currently waiting on its browser sign-in page, if any. */
export function waitingConnector(list: readonly ConnectorSignIn[]): ConnectorSignIn | undefined {
  return list.find((c) => c.waiting);
}
