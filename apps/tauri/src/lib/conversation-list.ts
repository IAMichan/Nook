import type { Conversation, ConversationSummary } from "./types";

export type ConversationGroupId = "pinned" | "today" | "yesterday" | "previous7" | "older";

/** Which age group a timestamp falls in, by calendar day in the viewer's time zone. A future date counts as today. */
export function dayBucket(updated: string, now: Date = new Date()): Exclude<ConversationGroupId, "pinned"> {
  const day = (offset: number) => new Date(now.getFullYear(), now.getMonth(), now.getDate() - offset).getTime();
  const time = new Date(updated).getTime();
  if (Number.isNaN(time) || time >= day(0)) return "today";
  if (time >= day(1)) return "yesterday";
  return time >= day(8) ? "previous7" : "older";
}

const GROUP_TITLES: Record<ConversationGroupId, string> = {
  pinned: "Pinned", today: "Today", yesterday: "Yesterday", previous7: "Previous 7 days", older: "Older",
};

/** Pinned first, then the rest by age as the Claude app lists them: Today, Yesterday, Previous 7 days, Older. */
export function conversationGroups(items: ConversationSummary[], activeId: string | null, now: Date = new Date()) {
  const visible = items.filter((item) => !item.archived && (item.preview || item.pinned || item.id === activeId));
  const recentFirst = (a: ConversationSummary, b: ConversationSummary) => b.updated.localeCompare(a.updated);
  const rest = visible.filter((item) => !item.pinned).sort(recentFirst);
  const ids: ConversationGroupId[] = ["pinned", "today", "yesterday", "previous7", "older"];
  return ids
    .map((id) => ({
      id,
      title: GROUP_TITLES[id],
      items: id === "pinned" ? visible.filter((item) => item.pinned).sort(recentFirst) : rest.filter((item) => dayBucket(item.updated, now) === id),
    }))
    .filter((group) => group.items.length);
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
