// The photos in chat messages (`inboxMedia`): asked for a few at a time, kept by message and version so a photo is
// fetched once and again only when it changed (`InboxLine.thumb`).
import { companion, MEDIA_BATCH, type InboxLine } from "../../lib/companion";

/** How many photos the phone keeps in memory at once (each at most 64 KB). */
const MAX_PHOTOS = 120;
const key = (line: string, version: string) => `${line}\u0000${version}`;

class MediaStore {
  /** Data URLs by message and version. */
  photos = $state<Record<string, string>>({});
  private asked = new Set<string>();
  private busy = false;
  /** What was asked for while a request ran: fetched right after it. */
  private next: { chat: string; lines: InboxLine[] } | null = null;

  /** The photo of a message, when it came. */
  photo(line: InboxLine): string | undefined {
    return line.thumb ? this.photos[key(line.id, line.thumb)] : undefined;
  }

  /** Asks for the photos of `lines` the phone does not have yet, `MEDIA_BATCH` per request, one request at a time. */
  async fetch(chat: string, lines: InboxLine[]): Promise<void> {
    if (this.busy) {
      this.next = { chat, lines };
      return;
    }
    const wanted = lines.filter((l) => l.thumb && !l.deleted && !this.asked.has(key(l.id, l.thumb)));
    if (!wanted.length) return;
    this.busy = true;
    try {
      for (let i = 0; i < wanted.length; i += MEDIA_BATCH) {
        const batch = wanted.slice(i, i + MEDIA_BATCH);
        for (const l of batch) this.asked.add(key(l.id, l.thumb ?? ""));
        const r = await companion.call({ op: "inboxMedia", item: chat, items: batch.map((l) => l.id) });
        if (!r.response) {
          // Not reachable: ask again next time.
          for (const l of batch) this.asked.delete(key(l.id, l.thumb ?? ""));
          return;
        }
        const next = { ...this.photos };
        for (const m of r.response.inboxMedia ?? []) next[key(m.line, m.version)] = `data:image/jpeg;base64,${m.jpeg}`;
        // The oldest go first past `MAX_PHOTOS`, so a long session does not hold every photo it saw.
        const keys = Object.keys(next);
        for (const k of keys.slice(0, Math.max(0, keys.length - MAX_PHOTOS))) {
          delete next[k];
          this.asked.delete(k);
        }
        this.photos = next;
      }
    } finally {
      this.busy = false;
      const next = this.next;
      this.next = null;
      if (next) void this.fetch(next.chat, next.lines);
    }
  }
}

export const media = new MediaStore();
