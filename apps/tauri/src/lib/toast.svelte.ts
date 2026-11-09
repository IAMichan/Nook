// The toasts of this window (Svelte 5 runes). Every window mounts one `Toast` (in App.svelte), so a result shows in the
// window where you did it.
import { ToastQueue, type Toast, type ToastKind } from "./toast";

class ToastStore {
  /// On screen, oldest first: the last one is in front.
  shown = $state<Toast[]>([]);
  /// The pointer is on the stack: every toast stays.
  paused = false;
  private queue = new ToastQueue((shown) => (this.shown = shown));
  private timer: ReturnType<typeof setInterval> | null = null;

  show(title: string, kind: ToastKind = "info", detail?: string) {
    this.queue.show(title, kind, detail);
    if (!this.timer) {
      this.timer = setInterval(() => {
        this.queue.advance(0.25, this.paused);
        if (this.queue.shown.length === 0 && this.timer) {
          clearInterval(this.timer);
          this.timer = null;
        }
      }, 250);
    }
  }

  success(title: string, detail?: string) {
    this.show(title, "success", detail);
  }

  info(title: string, detail?: string) {
    this.show(title, "info", detail);
  }

  warning(title: string, detail?: string) {
    this.show(title, "warning", detail);
  }

  /// What failed as the title, and the error itself under it.
  error(title: string, detail?: unknown) {
    this.show(title, "error", detail === undefined ? undefined : String(detail));
  }

  /// Closes toast `id`, or the one in front.
  dismiss(id?: number) {
    this.queue.dismiss(id);
    if (this.shown.length === 0) this.paused = false;
  }
}

export const toast = new ToastStore();
