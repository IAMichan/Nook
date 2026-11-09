// The one toast for a short result (the Mac's ToastCenter): "Pull request gemaakt", "Verstuurd naar Lisa", or what
// failed. A queue with a clock, without UI code, so tests can use it on its own; `toast.svelte.ts` makes it reactive.

export type ToastKind = "success" | "error" | "warning" | "info";

export interface Toast {
  id: number;
  kind: ToastKind;
  title: string;
  detail?: string;
}

/// How long a toast stays by itself: an error is read more slowly than a confirmation.
export const TOAST_SECONDS: Record<ToastKind, number> = { success: 3.5, info: 3.5, warning: 5, error: 7 };

/// How many toasts show at once, as a stack: the newest in front, the older ones peeking out under it.
export const TOAST_LIMIT = 3;

/// Up to `TOAST_LIMIT` toasts show at once, each with its own clock; the rest wait their turn. The same message twice
/// only restarts the clock of the first.
export class ToastQueue {
  /// On screen, oldest first: the last one is in front.
  shown: Toast[] = [];
  private waiting: Toast[] = [];
  private left = new Map<number, number>();
  private nextId = 1;

  constructor(private readonly changed: (shown: Toast[]) => void = () => {}) {}

  /// The newest toast on screen.
  get current(): Toast | null {
    return this.shown[this.shown.length - 1] ?? null;
  }

  show(title: string, kind: ToastKind = "info", detail?: string) {
    const text = title.trim();
    if (!text) return;
    const toast: Toast = { id: this.nextId++, kind, title: text, detail: detail?.trim() || undefined };
    const same = (other: Toast) => other.kind === toast.kind && other.title === toast.title && other.detail === toast.detail;
    const shown = this.shown.find(same);
    if (shown) {
      this.left.set(shown.id, TOAST_SECONDS[shown.kind]);
      return;
    }
    if (this.waiting.some(same)) return;
    if (this.shown.length < TOAST_LIMIT) this.present(toast);
    else this.waiting.push(toast);
  }

  /// `elapsed` seconds went by; while `paused` (the pointer is on the stack) every toast stays.
  advance(elapsed: number, paused: boolean) {
    if (paused) return;
    const expired: number[] = [];
    for (const toast of this.shown) {
      const left = (this.left.get(toast.id) ?? 0) - elapsed;
      this.left.set(toast.id, left);
      if (left <= 0) expired.push(toast.id);
    }
    for (const id of expired) this.dismiss(id);
  }

  /// Closes toast `id` (the one in front by default) and lets the next one waiting take its place.
  dismiss(id: number | undefined = this.current?.id) {
    if (id === undefined || !this.shown.some((toast) => toast.id === id)) return;
    this.left.delete(id);
    this.shown = this.shown.filter((toast) => toast.id !== id);
    const next = this.waiting.shift();
    if (next) this.present(next);
    else this.changed(this.shown);
  }

  private present(toast: Toast) {
    this.shown = [...this.shown, toast];
    this.left.set(toast.id, TOAST_SECONDS[toast.kind]);
    this.changed(this.shown);
  }
}
