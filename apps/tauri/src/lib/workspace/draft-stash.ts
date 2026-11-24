// Drafts set aside with Ctrl+S in a session's composer (`ComposerDraftStore.stash` and `stashKey` on the Mac): with
// words in the box the draft goes aside and the box empties; with an empty box the newest set-aside draft comes back.
// Shared by every composer, kept on this computer.

const KEY = "ws.draftStash";
const LIMIT = 20;

export function stashed(): string[] {
  try {
    const list = JSON.parse(localStorage.getItem(KEY) ?? "[]");
    return Array.isArray(list) ? list.filter((s): s is string => typeof s === "string" && s.trim() !== "") : [];
  } catch {
    return [];
  }
}

function save(list: string[]) {
  try {
    localStorage.setItem(KEY, JSON.stringify(list.slice(-LIMIT)));
  } catch {
    // No storage: the draft stays in the box.
  }
}

/// The key's effect on `draft`: the text the box shows afterwards (and nothing changes when there is nothing to do).
export function stashKey(draft: string): string {
  const list = stashed();
  if (draft.trim()) {
    save([...list, draft]);
    return "";
  }
  const back = list.pop();
  if (back === undefined) return draft;
  save(list);
  return back;
}
