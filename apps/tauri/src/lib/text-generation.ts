// Per-kind text generator helpers (`TextGenerators.swift` on macOS, SV-65).
import type { ProviderId, ProviderInfo } from "./types";

export type TextTask = "titles" | "gitText" | "nextPrompt";

export const TEXT_TASKS: readonly TextTask[] = ["titles", "gitText", "nextPrompt"];

export type TextGenerator =
  | { kind: "agent" }
  | { kind: "api"; provider: ProviderId; model: string };

/** Non-subscription brain providers that can generate text over their API. */
export function apiTextProviders(providers: readonly ProviderInfo[]): ProviderInfo[] {
  return providers.filter((p) => !p.isSubscription);
}

/** Wire format persisted in WorkspaceSettings: `"agent"` or `"api:<provider>:<model>"`. */
export function formatTextGenerator(gen: TextGenerator): string {
  if (gen.kind === "agent") return "agent";
  return `api:${gen.provider}:${gen.model.trim()}`;
}

/** Parses a stored setting; unknown or subscription providers fall back to `"agent"`. */
export function parseTextGenerator(
  stored: string | null | undefined,
  providers: readonly ProviderInfo[],
): TextGenerator {
  const raw = stored?.trim();
  if (!raw || !raw.startsWith("api:")) return { kind: "agent" };
  const rest = raw.slice(4);
  const colon = rest.indexOf(":");
  const providerId = (colon >= 0 ? rest.slice(0, colon) : rest) as ProviderId;
  const model = (colon >= 0 ? rest.slice(colon + 1) : "").trim();
  const known = providers.find((p) => p.id === providerId && !p.isSubscription);
  if (!known) return { kind: "agent" };
  return { kind: "api", provider: known.id, model };
}

/** Display title matching macOS (`Claude · API key` for Anthropic Messages API). */
export function textGeneratorProviderName(provider: ProviderInfo, claudeApiLabel: string): string {
  return provider.id === "claude" ? claudeApiLabel : provider.title;
}

/** Short summary shown on the collapsed Text generation header. */
export function textGeneratorSummary(
  stored: Record<string, string> | undefined,
  providers: readonly ProviderInfo[],
  agentLabel: string,
  claudeApiLabel: string,
): string {
  const parsed = TEXT_TASKS.map((t) => parseTextGenerator(stored?.[t], providers));
  const apiChoices = parsed.filter((g): g is Extract<TextGenerator, { kind: "api" }> => g.kind === "api");
  if (apiChoices.length === 0) return agentLabel;
  const first = providers.find((p) => p.id === apiChoices[0].provider);
  const firstName = first ? textGeneratorProviderName(first, claudeApiLabel) : apiChoices[0].provider;
  const allSame = apiChoices.length === TEXT_TASKS.length && apiChoices.every((g) => g.provider === apiChoices[0].provider);
  return allSame ? firstName : `${firstName} (+${TEXT_TASKS.length - 1})`;
}
