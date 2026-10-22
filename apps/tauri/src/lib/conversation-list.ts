import type { Conversation, ConversationSummary } from "./types";

export function conversationGroups(items: ConversationSummary[], activeId: string | null) {
  const visible = items.filter((item) => !item.archived && (item.preview || item.pinned || item.id === activeId));
  const recentFirst = (a: ConversationSummary, b: ConversationSummary) => b.updated.localeCompare(a.updated);
  return [
    { title: "Pinned", items: visible.filter((item) => item.pinned).sort(recentFirst) },
    { title: "Recent", items: visible.filter((item) => !item.pinned).sort(recentFirst) },
  ].filter((group) => group.items.length);
}

type ConversationListState = {
  activeId: string | null;
  active: Conversation | null;
  nooks: ConversationSummary[];
  refreshList: () => Promise<void>;
  select: (id: string) => Promise<void>;
};

/** Reconcile only the removed conversation, preserving a selection made while IPC was pending. */
export async function recoverDeletedConversation(state: ConversationListState, id: string) {
  const wasActive = state.activeId === id;
  if (wasActive) {
    state.activeId = null;
    state.active = null;
  }
  await state.refreshList();
  if (wasActive && state.activeId === null) {
    const next = state.nooks.find((item) => item.id !== id && !item.archived);
    if (next) await state.select(next.id);
  }
}
