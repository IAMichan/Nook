// Every emoji to choose from, as the Mac's `EmojiCatalog`: Unicode's groups in Unicode's order, each emoji with its
// English name, and a search over those names and Nook's own (Dutch ones too: "lachen", "hart"). `EmojiUsage` keeps
// the ones you choose most, fading over two weeks, so they come first. Both are shared by every chat integration.
import { EMOJI_GROUPS, EMOJI_SHORTCODES } from "./emoji-catalog-data";

export interface Emoji {
  character: string;
  /** Unicode's English name ("face with tears of joy"). */
  name: string;
}

export interface EmojiGroup {
  /** "smileys", "people", … (the Mac's `emoji.group.<key>`). */
  key: string;
  /** The Lucide icon of its tab. */
  icon: string;
  emoji: Emoji[];
}

function parse(table: string): Emoji[] {
  return table.split("\n").flatMap((line) => {
    const space = line.indexOf(" ");
    return space > 0 ? [{ character: line.slice(0, space), name: line.slice(space + 1) }] : [];
  });
}

export const emojiGroups: EmojiGroup[] = EMOJI_GROUPS.map((g) => ({ key: g.key, icon: g.icon, emoji: parse(g.table) }));
export const allEmoji: Emoji[] = emojiGroups.flatMap((g) => g.emoji);

const VS16 = "️";
const byCharacter = new Map<string, Emoji>();
for (const e of allEmoji) if (!byCharacter.has(e.character)) byCharacter.set(e.character, e);

/** The emoji for `character` with its name; one the catalog lacks (a skin tone, a newer emoji) keeps its character as name. */
export function emojiFor(character: string): Emoji {
  return byCharacter.get(character) ?? byCharacter.get(character + VS16) ?? byCharacter.get(character.replaceAll(VS16, "")) ?? { character, name: character };
}

// The words a search matches per emoji, in `allEmoji`'s order: its name's words and its shortcodes. Made once, on the
// first search.
let searchNames: string[][] | null = null;
function names(): string[][] {
  if (searchNames) return searchNames;
  const shortcodes = new Map<string, string[]>();
  for (const line of EMOJI_SHORTCODES.split("\n")) {
    const [head, ...rest] = line.split(" ");
    if (!head || rest.length === 0) continue;
    const character = head.endsWith("*") ? head.slice(0, -1) : head;
    if (!shortcodes.has(character)) shortcodes.set(character, rest);
  }
  searchNames = allEmoji.map((e) => [
    ...e.name.split(/[ -]/).filter(Boolean),
    ...(shortcodes.get(e.character) ?? shortcodes.get(e.character.replaceAll(VS16, "")) ?? []),
  ]);
  return searchNames;
}

/** The emoji whose names hold every word of `query`; those where every word starts a name come first. Empty for an empty query. */
export function searchEmoji(query: string, limit = 200): Emoji[] {
  const words = query.toLowerCase().split(" ").filter(Boolean);
  if (words.length === 0) return [];
  const all = names();
  const starts: Emoji[] = [];
  const contains: Emoji[] = [];
  for (let i = 0; i < allEmoji.length; i++) {
    const n = all[i];
    if (words.every((w) => n.some((name) => name.startsWith(w)))) starts.push(allEmoji[i]);
    else if (words.every((w) => n.some((name) => name.includes(w)))) contains.push(allEmoji[i]);
    if (starts.length >= limit) break;
  }
  return [...starts, ...contains].slice(0, limit);
}

/** One emoji's points as they stood at `last` (ms since 1970). */
export interface EmojiUsageEntry {
  score: number;
  last: number;
}

/** Where the counts are kept: localStorage in the app, a map in tests. */
export interface EmojiUsageStore {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

const DAY = 24 * 3600 * 1000;

/**
 * The emoji you choose most, as the Mac's `EmojiUsage`: one point per choice, halving every two weeks, the 64 strongest
 * kept. The picker shows the first 18 under "Frequently used" and puts them first in a search.
 */
export class EmojiUsage {
  static readonly shownCount = 18;
  static readonly keptCount = 64;
  static readonly halfLife = 14 * DAY;

  constructor(private store: EmojiUsageStore, private key = "chatEmojiUsage") {}

  static score(entry: EmojiUsageEntry, now: number): number {
    return entry.score * Math.pow(0.5, Math.max(0, now - entry.last) / EmojiUsage.halfLife);
  }

  get entries(): Record<string, EmojiUsageEntry> {
    try {
      const raw = this.store.getItem(this.key);
      const parsed = raw ? JSON.parse(raw) : {};
      return parsed && typeof parsed === "object" ? parsed : {};
    } catch {
      return {};
    }
  }

  /** Counts one choice of `character`. */
  record(character: string, now = Date.now()): void {
    if (!character) return;
    let all = this.entries;
    const previous = all[character] ? EmojiUsage.score(all[character], now) : 0;
    all[character] = { score: previous + 1, last: now };
    if (Object.keys(all).length > EmojiUsage.keptCount) {
      const kept = new Set(EmojiUsage.order(all, now).slice(0, EmojiUsage.keptCount));
      all = Object.fromEntries(Object.entries(all).filter(([k]) => kept.has(k)));
    }
    try {
      this.store.setItem(this.key, JSON.stringify(all));
    } catch {}
  }

  /** The emoji used most, most first; at most `limit`. */
  ranked(limit = EmojiUsage.shownCount, now = Date.now()): string[] {
    return EmojiUsage.order(this.entries, now).slice(0, limit);
  }

  /** `emoji` with the ones you use first (most first), the others after in their own order. */
  usedFirst<T>(emoji: T[], character: (item: T) => string, now = Date.now()): T[] {
    const rank = new Map(EmojiUsage.order(this.entries, now).map((c, i) => [c, i]));
    if (rank.size === 0) return emoji;
    return emoji
      .map((item, offset) => ({ item, offset, r: rank.get(character(item)) ?? Number.MAX_SAFE_INTEGER }))
      .sort((a, b) => a.r - b.r || a.offset - b.offset)
      .map((x) => x.item);
  }

  /** Highest score first; the last used first on a tie. */
  private static order(entries: Record<string, EmojiUsageEntry>, now: number): string[] {
    return Object.entries(entries)
      .map(([character, e]) => ({ character, score: EmojiUsage.score(e, now), last: e.last }))
      .sort((a, b) => b.score - a.score || b.last - a.last || (a.character < b.character ? -1 : a.character > b.character ? 1 : 0))
      .map((x) => x.character);
  }
}
