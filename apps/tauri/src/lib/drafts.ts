// What you were typing, per Nook. Switching to another Nook, closing the window or a crash no longer throws a half
// written question away: it is back in the field when you return. Kept in this window's storage, never sent anywhere.

type Storage = Pick<globalThis.Storage, "getItem" | "setItem">;

const KEY = "nook.drafts";
/// Older drafts beyond this are dropped, so the store cannot grow without end.
export const MAX_DRAFTS = 40;

type Saved = Record<string, { text: string; at: number }>;

export class Drafts {
  constructor(private readonly storage: Storage | null = safeStorage()) {}

  get(nookId: string | null): string {
    if (!nookId) return "";
    return this.read()[nookId]?.text ?? "";
  }

  /// An empty or blank text removes the draft.
  set(nookId: string | null, text: string, now = Date.now()) {
    if (!nookId) return;
    const all = this.read();
    if (text.trim()) all[nookId] = { text, at: now };
    else delete all[nookId];
    const kept = Object.entries(all).sort((a, b) => b[1].at - a[1].at).slice(0, MAX_DRAFTS);
    this.write(Object.fromEntries(kept));
  }

  clear(nookId: string | null) {
    this.set(nookId, "");
  }

  private read(): Saved {
    try {
      const parsed = JSON.parse(this.storage?.getItem(KEY) ?? "{}");
      return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
    } catch {
      return {};
    }
  }

  private write(all: Saved) {
    try { this.storage?.setItem(KEY, JSON.stringify(all)); } catch { /* Storage may be full or unavailable. */ }
  }
}

function safeStorage(): Storage | null {
  try { return typeof localStorage === "undefined" ? null : localStorage; } catch { return null; }
}

export const drafts = new Drafts();

