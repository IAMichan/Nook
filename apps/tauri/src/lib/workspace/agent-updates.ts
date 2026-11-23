// Updating coding agents (`AgentUpdates` on the Mac) and reading a failed turn that an update or a new sign-in fixes
// (`AgentVersionRejection`, `AgentSignInFailure`). The same rules as `nook_core::agents::updates` and
// `workspace::recovery`, for the interface.
import { invoke } from "@tauri-apps/api/core";
import type { AgentKind } from "../agents";

export interface AgentUpdateRow {
  kind: AgentKind;
  name: string;
  installed: string | null;
  latest: string | null;
  outdated: boolean;
  installer: string;
  command: string | null;
}

export const updatesApi = {
  list: (latest: boolean) => invoke<AgentUpdateRow[]>("agents_updates", { latest }),
  update: (kind: AgentKind) => invoke<string | null>("agents_update", { kind }),
};

/** The agents whose program Nook can update. */
export const updatable = (kind: string) => ["claude", "codex", "gemini", "opencode", "cursor", "grok"].includes(kind);

const REJECTION = [
  "requires a newer version of", "upgrade to the latest app or cli", "please upgrade to the latest version",
  "client version is too old", "this version of the cli is no longer supported",
];

/** Whether a failure says the API refused the agent's version for the model. */
export function versionRejected(text: string | null | undefined): boolean {
  if (!text) return false;
  if (/Claude Code \d+(\.\d+)+ does not support this model; version \d+(\.\d+)+ or newer is required/.test(text)) return true;
  const lower = text.toLowerCase();
  return REJECTION.some((p) => lower.includes(p));
}

const SIGN_IN = [
  "failed to authenticate", "authentication failed", "authentication_failed", "authentication_error",
  "authentication required", "requires authentication", "please authenticate", "auth required", "auth_required",
  "not authenticated", "not logged in", "not signed in", "please log in", "please login", "please sign in",
  "/login", "login required", "log in again", "sign in again", "oauth session expired", "oauth token",
  "token has expired", "token expired", "refresh token", "invalid_grant", "invalid api key", "invalid x-api-key",
  "api error: 401", "unauthorized", "unauthenticated", "credentials have expired", "no credentials",
  "session expired", "expired token", "login expired",
];

/** Whether a failure says the agent needs you to sign in again. */
export function needsSignIn(text: string | null | undefined): boolean {
  if (!text) return false;
  const lower = text.toLowerCase();
  return SIGN_IN.some((p) => lower.includes(p));
}
