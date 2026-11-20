// Per-session right side panel state (AG-100, mirroring macOS `SessionTools` / `SessionToolPanel` / `SidePanel`):
// each session remembers whether its side panel is open, which tool tabs it has open, which tab is active, and which
// tabs are pinned to the front. The panel's width is shared across sessions and persisted in localStorage.

export type SideTool = "outputs" | "subagents" | "terminal" | "browser" | "changes" | "pullRequest" | "file";
export type SideView = SideTool | "picker";

export interface SideToolMeta {
  id: SideTool;
  icon: string;
  key: string;
  needsFolder: boolean;
}

/** Tools in the exact order of macOS `SessionTool.launchable`, with their shortcut keys for the launcher. */
export const SIDE_TOOLS: SideToolMeta[] = [
  { id: "outputs", icon: "clipboard-list", key: "O", needsFolder: false },
  { id: "subagents", icon: "users", key: "S", needsFolder: false },
  { id: "terminal", icon: "terminal", key: "T", needsFolder: true },
  { id: "browser", icon: "globe", key: "B", needsFolder: false },
  { id: "changes", icon: "diff", key: "C", needsFolder: true },
  { id: "pullRequest", icon: "git-pull-request", key: "P", needsFolder: false },
  { id: "file", icon: "file-text", key: "F", needsFolder: false },
];

export interface SessionSideState {
  open: boolean;
  tabs: SideTool[];
  active: SideView;
  pinned: SideTool[];
  changesFile: string | null;
  terminalId: string | null;
  filePath: string | null;
  outputId: string | null;
}

const WIDTH_KEY = "agents.sidePanel.width";
export const DEFAULT_SIDE_WIDTH = 480;
export const MIN_SIDE_WIDTH = 320;
export const MAX_SIDE_WIDTH = 920;

function readWidth(): number {
  try {
    const raw = Number(localStorage.getItem(WIDTH_KEY));
    if (Number.isFinite(raw) && raw >= MIN_SIDE_WIDTH && raw <= MAX_SIDE_WIDTH) return raw;
  } catch {
    // Ignore storage failures.
  }
  return DEFAULT_SIDE_WIDTH;
}

function emptyState(): SessionSideState {
  return {
    open: false,
    tabs: [],
    active: "picker",
    pinned: [],
    changesFile: null,
    terminalId: null,
    filePath: null,
    outputId: null,
  };
}

function createSidePanelStore() {
  let sessions = $state<Record<string, SessionSideState>>({});
  let width = $state(readWidth());
  let maximized = $state(false);

  function ensure(runId: string): SessionSideState {
    let s = sessions[runId];
    if (!s) {
      s = emptyState();
      sessions[runId] = s;
    }
    return s;
  }

  function orderTabs(tabs: SideTool[], pinned: SideTool[]): SideTool[] {
    const pinSet = new Set(pinned);
    return [...tabs.filter((t) => pinSet.has(t)), ...tabs.filter((t) => !pinSet.has(t))];
  }

  return {
    get width() {
      return width;
    },
    get maximized() {
      return maximized;
    },
    /** Read-only view of a session's side panel state (safe inside `$derived`). */
    forRun(runId: string): SessionSideState {
      return sessions[runId] ?? emptyState();
    },
    /** Opens or closes the session's side panel, remembering its tabs and active tool. */
    toggle(runId: string) {
      const s = ensure(runId);
      if (s.open) {
        s.open = false;
        maximized = false;
      } else {
        s.open = true;
        if (s.active === "picker" && s.tabs.length) s.active = s.tabs[0];
      }
    },
    /** Closes the session's side panel without dropping its tabs. */
    close(runId: string) {
      const s = ensure(runId);
      s.open = false;
      maximized = false;
    },
    /** Opens a tool tab (adding it if needed) and focuses it in this session's side panel. */
    openTool(
      runId: string,
      tool: SideTool,
      opts?: { changesFile?: string | null; terminalId?: string | null; filePath?: string | null; outputId?: string | null },
    ) {
      const s = ensure(runId);
      if (!s.tabs.includes(tool)) s.tabs = orderTabs([...s.tabs, tool], s.pinned);
      s.active = tool;
      s.open = true;
      if (opts && "changesFile" in opts) s.changesFile = opts.changesFile ?? null;
      if (opts && "terminalId" in opts) s.terminalId = opts.terminalId ?? null;
      if (opts && "filePath" in opts) s.filePath = opts.filePath ?? null;
      if (opts && "outputId" in opts) s.outputId = opts.outputId ?? null;
    },
    /** Switches to an already-open tab or opens it. */
    selectTab(runId: string, tool: SideTool) {
      const s = ensure(runId);
      if (!s.tabs.includes(tool)) s.tabs = orderTabs([...s.tabs, tool], s.pinned);
      s.active = tool;
      s.open = true;
    },
    /** Closes one tab; if it was the last tab, shows the launcher ("Open a tool") matching macOS. */
    closeTab(runId: string, tool: SideTool) {
      const s = ensure(runId);
      const idx = s.tabs.indexOf(tool);
      if (idx < 0) return;
      s.tabs = s.tabs.filter((t) => t !== tool);
      s.pinned = s.pinned.filter((t) => t !== tool);
      if (s.active === tool) {
        s.active = s.tabs[Math.min(idx, s.tabs.length - 1)] ?? "picker";
      }
    },
    /** Pins or unpins a tab to the front of the session's tab strip. */
    togglePin(runId: string, tool: SideTool) {
      const s = ensure(runId);
      if (s.pinned.includes(tool)) {
        s.pinned = s.pinned.filter((t) => t !== tool);
      } else {
        s.pinned = [...s.pinned, tool];
      }
      s.tabs = orderTabs(s.tabs, s.pinned);
    },
    setFile(runId: string, filePath: string | null) {
      ensure(runId).filePath = filePath;
    },
    setOutput(runId: string, outputId: string | null) {
      ensure(runId).outputId = outputId;
    },
    setWidth(px: number) {
      const clamped = Math.round(Math.max(MIN_SIDE_WIDTH, Math.min(MAX_SIDE_WIDTH, px)));
      width = clamped;
      try {
        localStorage.setItem(WIDTH_KEY, String(clamped));
      } catch {
        // Ignore storage failures.
      }
    },
    resetWidth() {
      this.setWidth(DEFAULT_SIDE_WIDTH);
    },
    toggleMaximized() {
      maximized = !maximized;
    },
  };
}

export const sidePanel = createSidePanelStore();
