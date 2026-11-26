// The emoji you choose in chats (the emoji browser and the quick reaction row), so the picker opens with the ones you
// use most: the "Frequently Used" section and the clock tab. Shared by every chat integration, kept on this computer
// only. Ranked by frecency (the Mac's `EmojiUsage`): every choice adds one point, and points lose half their weight
// every two weeks.

export interface EmojiUsageEntry {
  score: number;
  /** Milliseconds since epoch when `score` was recorded. */
  last: number;
}

/** How many the picker shows: two rows of nine. */
export const EMOJI_SHOWN_COUNT = 18;
/** How many are remembered; the rest is dropped so the stored list stays small. */
export const EMOJI_KEPT_COUNT = 64;
/** After this long a point weighs half (14 days). */
export const EMOJI_HALF_LIFE_MS = 14 * 24 * 3600 * 1000;

const STORAGE_KEY = "nook.emoji.usage";
const LEGACY_KEY = "chats.emoji.frequent";

export type EmojiStorage = Pick<Storage, "getItem" | "setItem">;

function defaultStorage(): EmojiStorage | null {
  try {
    return typeof localStorage !== "undefined" ? localStorage : null;
  } catch {
    return null;
  }
}

/** Decayed score of `entry` at `now` (ms since epoch). */
export function emojiUsageScore(entry: EmojiUsageEntry, now: number): number {
  const elapsed = Math.max(0, now - entry.last);
  if (elapsed === 0) return entry.score;
  return entry.score * Math.pow(0.5, elapsed / EMOJI_HALF_LIFE_MS);
}

function orderEntries(entries: Record<string, EmojiUsageEntry>, now: number): string[] {
  return Object.entries(entries)
    .map(([character, entry]) => ({ character, score: emojiUsageScore(entry, now), last: entry.last }))
    .sort((a, b) => {
      if (a.score !== b.score) return b.score - a.score;
      if (a.last !== b.last) return b.last - a.last;
      return a.character < b.character ? -1 : a.character > b.character ? 1 : 0;
    })
    .map((item) => item.character);
}

export class EmojiUsageStore {
  private readonly storage: EmojiStorage | null;
  private readonly key: string;
  private readonly legacyKey: string | null;

  constructor(storage: EmojiStorage | null = defaultStorage(), key = STORAGE_KEY, legacyKey: string | null = LEGACY_KEY) {
    this.storage = storage;
    this.key = key;
    this.legacyKey = legacyKey;
  }

  entries(now = Date.now()): Record<string, EmojiUsageEntry> {
    if (!this.storage) return {};
    try {
      const raw = this.storage.getItem(this.key);
      if (raw) {
        const parsed = JSON.parse(raw) as Record<string, EmojiUsageEntry>;
        if (parsed && typeof parsed === "object") return parsed;
      }
      // Migrate legacy flat counts (`chats.emoji.frequent`) once if present.
      if (this.legacyKey) {
        const legacyRaw = this.storage.getItem(this.legacyKey);
        if (legacyRaw) {
          const counts = JSON.parse(legacyRaw) as Record<string, number>;
          if (counts && typeof counts === "object") {
            const migrated: Record<string, EmojiUsageEntry> = {};
            for (const [ch, count] of Object.entries(counts)) {
              if (ch && typeof count === "number" && count > 0) {
                migrated[ch] = { score: count, last: now };
              }
            }
            if (Object.keys(migrated).length) {
              this.save(migrated);
              return migrated;
            }
          }
        }
      }
    } catch {
      // Ignore corrupt or unavailable storage.
    }
    return {};
  }

  private save(next: Record<string, EmojiUsageEntry>) {
    try {
      this.storage?.setItem(this.key, JSON.stringify(next));
    } catch {
      // Ignore storage quota / privacy errors.
    }
  }

  /** Counts one choice of `character`. */
  record(character: string, now = Date.now()): void {
    if (!character) return;
    const all = { ...this.entries(now) };
    const previous = all[character] ? emojiUsageScore(all[character], now) : 0;
    all[character] = { score: previous + 1, last: now };
    const keys = Object.keys(all);
    if (keys.length > EMOJI_KEPT_COUNT) {
      const kept = new Set(orderEntries(all, now).slice(0, EMOJI_KEPT_COUNT));
      for (const key of keys) {
        if (!kept.has(key)) delete all[key];
      }
    }
    this.save(all);
  }

  /** The emoji used most, most first; at most `limit`. */
  ranked(limit = EMOJI_SHOWN_COUNT, now = Date.now()): string[] {
    return orderEntries(this.entries(now), now).slice(0, limit);
  }

  /** `items` with the ones you use first (most first), the others after in their own order. */
  usedFirst<T>(items: readonly T[], character: (item: T) => string, now = Date.now()): T[] {
    const ordered = orderEntries(this.entries(now), now);
    if (!ordered.length) return [...items];
    const rank = new Map<string, number>();
    ordered.forEach((ch, idx) => rank.set(ch, idx));
    return items
      .map((item, offset) => ({ item, offset, r: rank.get(character(item)) ?? Number.MAX_SAFE_INTEGER }))
      .sort((a, b) => (a.r !== b.r ? a.r - b.r : a.offset - b.offset))
      .map((x) => x.item);
  }
}

export const emojiUsage = new EmojiUsageStore();
