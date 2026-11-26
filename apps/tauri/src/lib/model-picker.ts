// Pure logic for the one shared model picker (`ModelPickerDropdown` / `ModelPicker` on the Mac): rail grouping,
// keyboard highlight stepping over enabled rows, Ctrl/Cmd+1..9 row selection, and model name search matching.

export const MODEL_PICKER_WIDTH = 340;
export const MODEL_PICKER_SIDE_WIDTH = 170;
export const MODEL_PICKER_LIST_HEIGHT = 240;

/** A place in the model picker's rail: this computer, a cross-agent choice ("Auto"), or an agent/service/account. */
export interface ModelPickerPlace {
  id: string;
  /** The agent or service's name: the column's title and brand logo key. */
  name: string;
  /** Optional subtitle under the column header (e.g. account name or local-brain explanation). */
  detail?: string;
  /** Tooltip on the rail icon; defaults to `name` (or `name · detail` when non-local with detail). */
  help?: string;
  /** This computer's own local models (drawn as a laptop icon in the first rail group). */
  isLocal?: boolean;
  /** A cross-agent choice such as "Auto" (drawn as a Lucide icon in its own group; hides search by default). */
  symbol?: string;
  /** Dimmed in the rail (e.g. an agent not installed on this computer). */
  dimmed?: boolean;
  /** Whether the column shows the search input; defaults to `true` unless `symbol` is set. */
  searchable?: boolean;
}

/** One row in a place's column: a model, or an action after the models ("Use model …", "Fetch models"). */
export interface ModelPickerItem {
  id: string;
  title: string;
  brand?: string;
  symbol?: string;
  detail?: string;
  trailing?: string;
  chosen?: boolean;
  disabledReason?: string;
  staysOpen?: boolean;
  /** Show the favorite star when defined (`true` = starred, `false` = unstarred). */
  favorite?: boolean;
  onstar?: () => void;
  onpick: () => void;
}

/** What one place's column lists. */
export interface ModelPickerList {
  models: ModelPickerItem[];
  actions?: ModelPickerItem[];
  emptyNote?: string;
}

/** Splits places into up to three rail groups (local, symbol/cross-agent, agents/services), omitting empty groups. */
export function groupPlaces(places: readonly ModelPickerPlace[]): ModelPickerPlace[][] {
  const local = places.filter((p) => p.isLocal);
  const symbolic = places.filter((p) => !p.isLocal && !!p.symbol);
  const agents = places.filter((p) => !p.isLocal && !p.symbol);
  return [local, symbolic, agents].filter((g) => g.length > 0);
}

/** Tooltip text for a place in the rail (`ModelPicker.help(of:)`). */
export function placeHelp(place: ModelPickerPlace): string {
  if (place.help) return place.help;
  if (!place.isLocal && place.detail) return `${place.name} · ${place.detail}`;
  return place.name;
}

/** Clamps `index` to the nearest enabled row (or the first enabled row), returning `null` if none are enabled. */
export function clampedHighlight(index: number, enabled: readonly boolean[]): number | null {
  if (!enabled.length) return null;
  if (index >= 0 && index < enabled.length && enabled[index]) return index;
  for (let i = Math.max(0, Math.min(index, enabled.length - 1)); i < enabled.length; i++) {
    if (enabled[i]) return i;
  }
  for (let i = Math.min(index, enabled.length - 1); i >= 0; i--) {
    if (enabled[i]) return i;
  }
  return null;
}

/** Moves the highlight forward or backward over enabled rows (`ListHighlight.step`). */
export function stepHighlight(current: number | null, delta: 1 | -1, enabled: readonly boolean[]): number | null {
  if (!enabled.length) return null;
  if (current === null) return delta > 0 ? clampedHighlight(0, enabled) : clampedHighlight(enabled.length - 1, enabled);
  for (let i = current + delta; i >= 0 && i < enabled.length; i += delta) {
    if (enabled[i]) return i;
  }
  return current;
}

/** Resolves 1..9 keyboard shortcut to the nth enabled model index (`ModelPickerKeys.row`). */
export function numberKeyRow(number: number, enabled: readonly boolean[]): number | null {
  if (number < 1 || number > 9) return null;
  let seen = 0;
  for (let i = 0; i < enabled.length; i++) {
    if (!enabled[i]) continue;
    seen += 1;
    if (seen === number) return i;
  }
  return null;
}

/** Matches a model's names against search text (`ModelSearch.matches`). */
export function modelSearchMatches(query: string, ...names: string[]): boolean {
  const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
  if (!words.length) return true;
  const hay = names.join(" ").toLowerCase();
  return words.every((w) => hay.includes(w));
}

/** Whether a model's ID says more than its display name (`ModelSearch.idAddsToName`). */
export function idAddsToName(id: string, name: string): boolean {
  const alnum = (s: string) => s.toLowerCase().replace(/[^a-z0-9]/g, "");
  return id.length > 0 && alnum(id) !== alnum(name);
}
