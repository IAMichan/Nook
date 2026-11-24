// Hold Ctrl alone for a moment to see the keys (the Mac's `CommandHoldMonitor`): after 200 ms with only Ctrl down, the
// sidebar's tabs and lists show their Ctrl+number (`KeyHint.svelte`). Any other key, another modifier, letting go or
// leaving the window hides them; a shortcut typed straight away never shows them. While held, `<html>` carries
// `keys-held`, so a list outside the shell can show its own hints with CSS alone.
import { holdsCtrlAlone } from "./key-hold";

const DELAY = 200;

class KeyHold {
  held = $state(false);
  private timer: ReturnType<typeof setTimeout> | undefined;
  private users = 0;

  private set(value: boolean) {
    if (this.held === value) return;
    this.held = value;
    document.documentElement.classList.toggle("keys-held", value);
  }

  private cancel() {
    clearTimeout(this.timer);
    this.timer = undefined;
  }

  private readonly down = (e: KeyboardEvent) => {
    if (holdsCtrlAlone(e) && !e.repeat) {
      this.cancel();
      this.timer = setTimeout(() => {
        this.timer = undefined;
        this.set(true);
      }, DELAY);
    } else if (!holdsCtrlAlone(e)) {
      // A shortcut typed straight away, or another modifier: no hints for it.
      this.cancel();
      this.set(false);
    }
  };

  private readonly up = () => {
    this.cancel();
    this.set(false);
  };

  /// Starts watching while a view that shows hints is on screen; returns the stop, for `$effect`.
  watch(): () => void {
    if (this.users++ === 0) {
      window.addEventListener("keydown", this.down, true);
      window.addEventListener("keyup", this.up, true);
      window.addEventListener("blur", this.up);
    }
    return () => {
      if (--this.users > 0) return;
      window.removeEventListener("keydown", this.down, true);
      window.removeEventListener("keyup", this.up, true);
      window.removeEventListener("blur", this.up);
      this.up();
    };
  }
}

export const keyHold = new KeyHold();
