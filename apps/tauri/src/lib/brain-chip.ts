// The brain chip under the composer (the Mac's `BrainChip`): which model Nook thinks with, and the picker behind it with
// a rail of places — on this computer (Ollama, LM Studio) and every agent Nook can think through with your own sign-in —
// each with its models, a search, and stars that put favourites on top.
import type { ProviderInfo, Settings } from "./types";
import type { ServerModel } from "./brain";

/// "Claude Code" instead of "Claude Code (je abonnement)", "Ollama" instead of "Ollama (op deze computer)".
export function shortTitle(title: string): string {
  return title.split(" (")[0];
}

/// Thinks through an agent's own sign-in (no key) rather than a server on this computer or an API.
export function isSubscription(p: ProviderInfo): boolean {
  return !p.isLocal && !p.needsKey;
}

export function activeModel(settings: Pick<Settings, "provider" | "providerModels">, providers: ProviderInfo[]): string {
  const info = providers.find((p) => p.id === settings.provider);
  return settings.providerModels[settings.provider] ?? info?.defaultModel ?? "";
}

/// What the pill says: the model on this computer, or "agent · model", or "service · model".
export function pillText(settings: Pick<Settings, "provider" | "providerModels">, providers: ProviderInfo[], firstModel: string): string {
  const info = providers.find((p) => p.id === settings.provider);
  const model = activeModel(settings, providers);
  if (info?.isLocal) return model || firstModel;
  const name = shortTitle(info?.title ?? settings.provider);
  return model ? `${name} · ${model}` : name;
}

export interface PickerPlace {
  /// "local" or a provider id.
  id: string;
  name: string;
  isLocal: boolean;
}

export interface PickerModel {
  id: string;
  title: string;
  /// "Ollama" or "LM Studio" for a model on this computer.
  trailing?: string;
  chosen: boolean;
  /// What choosing it sets.
  pick: { kind: "local"; server: ServerModel["server"]; name: string } | { kind: "provider"; provider: string; model: string };
}

/// The places in the rail: this computer first, then the agents Nook can think through.
export function places(providers: ProviderInfo[], localName: string): PickerPlace[] {
  return [{ id: "local", name: localName, isLocal: true }, ...providers.filter(isSubscription).map((p) => ({ id: p.id, name: shortTitle(p.title), isLocal: false }))];
}

/// The place the chosen brain belongs to, where the picker opens.
export function placeOf(settings: Pick<Settings, "provider">, providers: ProviderInfo[]): string {
  const info = providers.find((p) => p.id === settings.provider);
  return info && isSubscription(info) ? info.id : "local";
}

function matches(query: string, text: string): boolean {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean);
  const hay = text.toLowerCase();
  return words.every((w) => hay.includes(w));
}

/// The models of a place, filtered by `query`, favourites first (otherwise in their own order).
export function models(
  place: string,
  settings: Pick<Settings, "provider" | "providerModels">,
  providers: ProviderInfo[],
  servers: ServerModel[],
  query: string,
  favorites: Set<string>,
): PickerModel[] {
  const current = activeModel(settings, providers);
  let list: PickerModel[];
  if (place === "local") {
    list = servers
      .filter((m) => matches(query, m.name))
      .map((m) => ({
        id: m.name,
        title: m.name,
        trailing: m.server === "ollama" ? "Ollama" : "LM Studio",
        chosen: settings.provider === m.server && current === m.name,
        pick: { kind: "local", server: m.server, name: m.name },
      }));
  } else {
    const info = providers.find((p) => p.id === place);
    const names = [...(info?.suggestedModels ?? [])];
    // The model in use stays listed even when it is not one of the suggestions.
    if (settings.provider === place && current && !names.includes(current)) names.push(current);
    list = names
      .filter((m) => matches(query, m))
      .map((m) => ({ id: m, title: m, chosen: settings.provider === place && current === m, pick: { kind: "provider", provider: place, model: m } }));
  }
  return [...list.filter((m) => favorites.has(m.id)), ...list.filter((m) => !favorites.has(m.id))];
}

const FAVORITES = "brain.favorites.";

export function loadFavorites(place: string, storage: Pick<Storage, "getItem"> = localStorage): Set<string> {
  try {
    return new Set(JSON.parse(storage.getItem(FAVORITES + place) ?? "[]") as string[]);
  } catch {
    return new Set();
  }
}

export function toggleFavorite(place: string, id: string, storage: Pick<Storage, "getItem" | "setItem"> = localStorage): Set<string> {
  const set = loadFavorites(place, storage);
  if (set.has(id)) set.delete(id);
  else set.add(id);
  storage.setItem(FAVORITES + place, JSON.stringify([...set]));
  return set;
}
