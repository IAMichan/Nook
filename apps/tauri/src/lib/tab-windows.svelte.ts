// Split view's state for the main window and the tabs torn off into a window of their own (the Mac's `PanelSplit`
// and `TabWindowController`): which tab sits beside the main one, how wide, and which tabs have a window. The windows
// are made in Rust (`platform/tab_windows.rs`) and open again after a restart.
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { SPLIT_KEY, SPLIT_WIDTH_KEY, TAB_WINDOWS_KEY, LAYOUT_SPLIT, isSplitTab, storedTabWindows, type SplitTab } from "./panel-split";
import { storeWidth, storedWidth } from "./panel-resize";

function read(key: string): string | null {
  try { return localStorage.getItem(key); } catch { return null; }
}
function write(key: string, value: string | null) {
  try {
    if (value === null) localStorage.removeItem(key);
    else localStorage.setItem(key, value);
  } catch { /* remembering is a convenience */ }
}

class Split {
  /// The tab chosen to sit beside the main one ("" while split view is off).
  stored = $state<string>(read(SPLIT_KEY) ?? "");
  width = $state(storedWidth(SPLIT_WIDTH_KEY, LAYOUT_SPLIT));
  windows = $state<SplitTab[]>(storedTabWindows(read(TAB_WINDOWS_KEY)));

  choose(tab: SplitTab | null) {
    this.stored = tab ?? "";
    write(SPLIT_KEY, tab);
  }

  setWidth(width: number) {
    this.width = width;
    storeWidth(SPLIT_WIDTH_KEY, width);
  }

  private remember(list: SplitTab[]) {
    this.windows = list;
    write(TAB_WINDOWS_KEY, JSON.stringify(list));
  }

  /// Puts `tab` in a window of its own (or brings its window forward); it leaves the side of the main tab.
  async openWindow(tab: SplitTab) {
    if (this.stored === tab) this.choose(null);
    await invoke("open_tab_window", { tab });
    if (!this.windows.includes(tab)) this.remember([...this.windows, tab]);
  }

  /// Opens the windows that were open when Nook last stopped. Called once, by the main window.
  reopen() {
    for (const tab of this.windows) invoke("open_tab_window", { tab, focus: false }).catch(() => {});
  }

  /// Follows windows closed by hand (`tab-window-closed` from Rust) and choices made in another window.
  follow(): () => void {
    const un = listen<string>("tab-window-closed", (e) => {
      if (isSplitTab(e.payload)) this.remember(this.windows.filter((t) => t !== e.payload));
    });
    const storage = (e: StorageEvent) => {
      if (e.key === SPLIT_KEY) this.stored = e.newValue ?? "";
      if (e.key === TAB_WINDOWS_KEY) this.windows = storedTabWindows(e.newValue);
    };
    window.addEventListener("storage", storage);
    return () => {
      un.then((f) => f()).catch(() => {});
      window.removeEventListener("storage", storage);
    };
  }
}

export const split = new Split();

/// From a torn-off window: closes it and puts its tab back beside the main tab (`split.dock` on the Mac).
export async function dockTabWindow(tab: SplitTab) {
  split.choose(tab);
  await invoke("close_tab_window", { tab, dock: true });
}
