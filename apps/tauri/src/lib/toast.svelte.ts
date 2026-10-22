// The toast of this window (Svelte 5 runes). Every window mounts one `Toast` (in App.svelte), so a result shows in the
// window where you did it.
import { ToastQueue, type Toast, type ToastKind } from "./toast";

class ToastStore {
  current = $state<Toast | null>(null);
  /// The pointer is on the toast: it stays.
  paused = false;
  private queue = new ToastQueue((current) => (this.current = current));
  private timer: ReturnType<typeof setInterval> | null = null;

  show(title: string, kind: ToastKind = "info", detail?: string) {
    this.queue.show(title, kind, detail);
    if (!this.timer) {
      this.timer = setInterval(() => {
        this.queue.advance(0.25, this.paused);
        if (!this.queue.current && this.timer) {
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

  dismiss() {
    this.paused = false;
    this.queue.dismiss();
  }
}

export const toast = new ToastStore();
