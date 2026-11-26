// Every emoji, grouped as Unicode groups them (smileys, people, animals…), in Unicode's own order, each with its
// English name and Nook's own shortcodes for searching (the Mac's `EmojiCatalog`).
import { tr } from "./i18n.svelte";
import { EMOJI_GROUP_SOURCES, EMOJI_SHORTCODE_TABLE, type EmojiGroupId } from "./emoji-data";

export type { EmojiGroupId };

export interface EmojiItem {
  readonly character: string;
  /** Unicode's English name ("face with tears of joy"). */
  readonly name: string;
}

export interface EmojiGroup {
  readonly id: EmojiGroupId;
  /** Lucide icon name for its tab. */
  readonly icon: string;
  readonly emoji: readonly EmojiItem[];
}

let cachedGroups: readonly EmojiGroup[] | null = null;
let cachedAll: readonly EmojiItem[] | null = null;
let cachedByCharacter: Map<string, EmojiItem> | null = null;
let cachedSearchNames: readonly (readonly string[])[] | null = null;

function parseGroups(): readonly EmojiGroup[] {
  if (cachedGroups) return cachedGroups;
  cachedGroups = EMOJI_GROUP_SOURCES.map((source) => {
    const emoji: EmojiItem[] = [];
    for (const line of source.table.split("\n")) {
      const space = line.indexOf(" ");
      if (space <= 0) continue;
      emoji.push({ character: line.slice(0, space), name: line.slice(space + 1) });
    }
    return { id: source.id, icon: source.icon, emoji };
  });
  return cachedGroups;
}

export function emojiGroups(): readonly EmojiGroup[] {
  return parseGroups();
}

export function allEmoji(): readonly EmojiItem[] {
  if (!cachedAll) cachedAll = parseGroups().flatMap((g) => g.emoji);
  return cachedAll;
}

function byCharacterMap(): Map<string, EmojiItem> {
  if (cachedByCharacter) return cachedByCharacter;
  const map = new Map<string, EmojiItem>();
  for (const item of allEmoji()) {
    if (!map.has(item.character)) map.set(item.character, item);
  }
  cachedByCharacter = map;
  return map;
}

function stripVS16(value: string): string {
  return value.replaceAll("\uFE0F", "");
}

/** The emoji for `character`, with its name; one the catalog lacks (a skin tone, a newer emoji) keeps its character as its name. */
export function emojiFor(character: string): EmojiItem {
  const map = byCharacterMap();
  return (
    map.get(character) ??
    map.get(`${character}\uFE0F`) ??
    map.get(stripVS16(character)) ?? { character, name: character }
  );
}

function searchNames(): readonly (readonly string[])[] {
  if (cachedSearchNames) return cachedSearchNames;
  const shortcodes = new Map<string, string[]>();
  for (const line of EMOJI_SHORTCODE_TABLE.split("\n")) {
    const parts = line.trim().split(/\s+/);
    if (parts.length < 2) continue;
    const ch = parts[0];
    const codes = parts.slice(1).map((c) => c.toLowerCase());
    if (!shortcodes.has(ch)) shortcodes.set(ch, codes);
    const bare = stripVS16(ch);
    if (!shortcodes.has(bare)) shortcodes.set(bare, codes);
  }
  cachedSearchNames = allEmoji().map((item) => {
    const words = item.name.toLowerCase().split(/[\s-]+/).filter(Boolean);
    const extra = shortcodes.get(item.character) ?? shortcodes.get(stripVS16(item.character)) ?? [];
    return extra.length ? [...words, ...extra] : words;
  });
  return cachedSearchNames;
}

/**
 * The emoji whose name (or one of Nook's own names for it, Dutch ones too: "lachen", "hart") holds every word of
 * `query`; words that start a name's word count first. Empty for an empty query.
 */
export function searchEmoji(query: string, limit = 200): EmojiItem[] {
  const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
  if (!words.length) return [];
  const items = allEmoji();
  const namesList = searchNames();
  const starts: EmojiItem[] = [];
  const contains: EmojiItem[] = [];
  for (let i = 0; i < items.length; i++) {
    const names = namesList[i];
    if (words.every((w) => names.some((n) => n.startsWith(w)))) {
      starts.push(items[i]);
    } else if (words.every((w) => names.some((n) => n.includes(w)))) {
      contains.push(items[i]);
    }
    if (starts.length >= limit) break;
  }
  return starts.length >= limit ? starts.slice(0, limit) : [...starts, ...contains].slice(0, limit);
}

/** Localized section header / tab label for an emoji group (`emoji.group.*`). */
export function emojiGroupLabel(id: EmojiGroupId | "recent"): string {
  switch (id) {
    case "recent": return tr("Veelgebruikt", "Frequently Used");
    case "smileys": return tr("Smileys en emoties", "Smileys & Emotion");
    case "people": return tr("Mensen en lichaam", "People & Body");
    case "animals": return tr("Dieren en natuur", "Animals & Nature");
    case "food": return tr("Eten en drinken", "Food & Drink");
    case "travel": return tr("Reizen en plaatsen", "Travel & Places");
    case "activities": return tr("Activiteiten", "Activities");
    case "objects": return tr("Voorwerpen", "Objects");
    case "symbols": return tr("Symbolen", "Symbols");
    case "flags": return tr("Vlaggen", "Flags");
  }
}
