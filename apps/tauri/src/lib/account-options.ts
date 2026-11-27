// Pure helpers for agent account options (`AccountOptionsSection` on the Mac, CH-98): splitting multiline arguments/models,
// validating shell variable names, detecting home-variable clashes, and filtering disabled accounts from pickers.
import type { AgentProfile } from "./agents";

/** Non-empty trimmed lines, preserving order (`AccountOptionsSection.split` on the Mac). */
export function splitLines(text: string): string[] {
  return text
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0);
}

/** Letters, digits, and underscores, not starting with a digit (`AccountVariable.isValidName` on the Mac). */
export function isValidVariableName(name: string): boolean {
  return /^[A-Za-z_][A-Za-z0-9_]*$/.test(name);
}

/** Returns the home-folder variable name if any edited row tries to override a folder variable Nook sets itself. */
export function clashingHomeVariable(profile: Pick<AgentProfile, "home" | "homeVariable">, names: string[]): string | null {
  if (!profile.home || !profile.homeVariable) return null;
  return names.some((n) => n.trim() === profile.homeVariable) ? profile.homeVariable : null;
}

/** Accounts offered in pickers: enabled accounts only, plus `keepId` when an existing session already uses it. */
export function pickableProfiles(profiles: AgentProfile[], keepId?: string | null): AgentProfile[] {
  return profiles.filter((p) => p.enabled !== false || (!!keepId && p.id === keepId));
}

/** Custom model names configured on an account, trimmed and deduplicated. */
export function accountCustomModels(profile: Pick<AgentProfile, "customModels"> | null | undefined): string[] {
  if (!profile?.customModels?.length) return [];
  const seen = new Set<string>();
  const out: string[] = [];
  for (const raw of profile.customModels) {
    const clean = raw.trim();
    if (clean && !seen.has(clean)) {
      seen.add(clean);
      out.push(clean);
    }
  }
  return out;
}
