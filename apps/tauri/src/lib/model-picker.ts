// What the one model picker (`ModelPicker.svelte`) is built from, as on the Mac (`ModelPicker.swift`,
// `ListHighlight`, `ModelPickerKeys`, `ModelSearch`): the places in its rail, the rows of a place's column, and the
// pure rules for the search, the highlight that ↑/↓ move, and the row Ctrl+1…9 picks. Callers hand over places and a
// list per place; never build a second model menu.

/** A place in the rail: an agent or service (once per account when it has several), this computer, or a choice that spans every agent. */
export interface ModelPickerPlace {
  id: string;
  /** The agent or service's name: the column's title, and what picks its logo. */
  name: string;
  /** A letter or short tag on the logo: whose account it runs under, or an API key. */
  account?: string;
  /** The line under the column's title: the account's name when an agent shows once per account. */
  detail?: string;
  /** This computer's own models, drawn as a laptop instead of a logo, first and set apart. */
  isLocal?: boolean;
  /** A choice that spans every agent ("Auto"): drawn as this Lucide icon in a group of its own, its column without a search. */
  icon?: string;
}

/** One row of a place's column: a model, or an action between the models ("Use model …", "Fetch models"). */
export interface ModelPickerItem {
  id: string;
  title: string;
  /** Whose logo the row shows (an agent or brand name); none for an action. */
  brand?: string;
  account?: string;
  /** A Lucide icon instead of a logo, for an action. */
  icon?: string;
  detail?: string;
  trailing?: string;
  chosen?: boolean;
  /** Set when the model cannot be picked yet (it needs a newer agent); its tooltip says why. */
  disabledReason?: string;
  /** The panel stays open after the pick (a toggle, fetching models). */
  staysOpen?: boolean;
  /** The star; undefined leaves it out. */
  favorite?: boolean;
  onfavorite?: (on: boolean) => void;
  pick: () => void;
}

/** What one place's column lists. */
export interface ModelPickerList {
  models: ModelPickerItem[];
  /** Rows after the models: a model of your own typed in the search, fetching the full list. */
  actions?: ModelPickerItem[];
  /** Said when nothing is listed; by default "No models found". */
  emptyNote?: string;
}

export const MODEL_PICKER = {
  width: 340,
  /** The models scroll past this height, which keeps the whole panel on screen under a composer. */
  listHeight: 240,
  markSize: 18,
  /** The column of reasoning levels beside the models. */
  sideWidth: 170,
  /** Ctrl+1…9 pick the nth model. */
  numberKeys: 9,
} as const;

/** The rail's groups, each set apart: this computer first, then the choices across agents, then the agents and services. Empty groups drop out. */
export function railGroups(places: ModelPickerPlace[]): ModelPickerPlace[][] {
  return [places.filter((p) => p.isLocal), places.filter((p) => !p.isLocal && p.icon), places.filter((p) => !p.isLocal && !p.icon)].filter((g) => g.length > 0);
}

/** A place's tooltip in the rail: its name, with the account after a dot when it shows once per account. */
export function placeHelp(place: ModelPickerPlace): string {
  return !place.isLocal && place.detail ? `${place.name} · ${place.detail}` : place.name;
}

/** Whether any of `names` holds the search text (case-insensitive); an empty search matches everything. */
export function modelMatches(query: string, ...names: string[]): boolean {
  const needle = query.trim().toLowerCase();
  return !needle || names.some((n) => n.toLowerCase().includes(needle));
}

/** Whether a model's id says more than its name, so it earns a line under it ("claude-opus-4-1-20250805" adds a date). */
export function idAddsToName(id: string, name: string): boolean {
  const letters = (t: string) => t.toLowerCase().replace(/[^\p{L}\p{N}]/gu, "");
  return id !== "" && letters(id) !== letters(name);
}

/** `index` if that row can be picked, else the first one after it that can, else the last one before it; null when none can. */
export function clampHighlight(index: number, enabled: boolean[]): number | null {
  if (!enabled.includes(true)) return null;
  const start = Math.min(Math.max(index, 0), enabled.length - 1);
  const after = enabled.indexOf(true, start);
  if (after >= 0) return after;
  return enabled.lastIndexOf(true, start - 1);
}

/** The next row that can be picked `offset` rows on (1 down, -1 up), staying at the ends; null when none can. */
export function stepHighlight(index: number | null, offset: number, enabled: boolean[]): number | null {
  if (index === null) return clampHighlight(0, enabled);
  let next = index + offset;
  while (next >= 0 && next < enabled.length) {
    if (enabled[next]) return next;
    next += offset;
  }
  return index;
}

/** The row Ctrl+`number` picks: the nth model as shown (a disabled one keeps its number); null past the end or on a disabled row. */
export function numberKeyRow(number: number, enabled: boolean[]): number | null {
  if (number < 1 || number > MODEL_PICKER.numberKeys || number > enabled.length || !enabled[number - 1]) return null;
  return number - 1;
}
