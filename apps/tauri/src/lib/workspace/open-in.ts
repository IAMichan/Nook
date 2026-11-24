// Settings › Sessions › Editor & browser, apart from the editor (`WorkspaceSettings.editor`): the terminal a folder
// opens in, Nook's browser's search engine, where a link in an agent's conversation opens, and remembering visited
// pages. Kept by the backend in `open-in.json` (`core/src/workspace/open_in.rs`).
import { invoke } from "@tauri-apps/api/core";
import { openUrl } from "@tauri-apps/plugin-opener";

export type SearchEngine = "duckduckgo" | "google" | "bing" | "brave" | "kagi" | "startpage" | "ecosia";
export type LinkTarget = "app" | "system";

export interface OpenInPrefs {
  terminal: string;
  searchEngine: SearchEngine;
  linkTarget: LinkTarget;
  rememberHistory: boolean;
}

export interface Visit {
  url: string;
  title: string;
  at: number;
}

/** The search engines in the Mac's order, with their names. */
export const searchEngines: { id: SearchEngine; name: string }[] = [
  { id: "duckduckgo", name: "DuckDuckGo" },
  { id: "google", name: "Google" },
  { id: "bing", name: "Bing" },
  { id: "brave", name: "Brave Search" },
  { id: "kagi", name: "Kagi" },
  { id: "startpage", name: "Startpage" },
  { id: "ecosia", name: "Ecosia" },
];

export const openInApi = {
  prefs: () => invoke<OpenInPrefs>("open_in_prefs"),
  save: (prefs: OpenInPrefs) => invoke<OpenInPrefs>("open_in_set_prefs", { prefs }),
  terminals: () => invoke<{ id: string; name: string }[]>("workspace_terminals"),
  /** Opens `folder` in the chosen terminal; the id of a Nook terminal when it opened one. */
  openTerminal: (folder: string) => invoke<string | null>("workspace_open_terminal", { folder }),
  historyCount: () => invoke<number>("browser_history_count"),
  clearHistory: () => invoke<void>("browser_history_clear"),
  suggest: (text: string) => invoke<Visit[]>("browser_history_suggest", { text }),
};

let linkTarget: LinkTarget | null = null;

/** Remembers a just-saved choice, so the next link click follows it without asking the backend again. */
export function setLinkTarget(target: LinkTarget) {
  linkTarget = target;
}

/** Where a link opens: Nook's browser for "app" (the default), your own browser for "system"; Ctrl or ⌘ while clicking
 *  picks the other one for that link, as on the Mac. */
export function linkOpensInNook(target: LinkTarget, otherWay: boolean): boolean {
  return (target === "app") !== otherWay;
}

/** Opens a web link from an agent's conversation where Settings › Sessions › Editor & browser says. */
export async function openAgentLink(url: string, otherWay: boolean) {
  if (linkTarget === null) linkTarget = (await openInApi.prefs().catch(() => null))?.linkTarget ?? "app";
  if (/^https?:\/\//i.test(url) && linkOpensInNook(linkTarget, otherWay)) {
    try {
      await invoke("browser_go", { input: url });
      return;
    } catch {
      // No browser window here (a phone): fall through to the system browser.
    }
  }
  await openUrl(url);
}
