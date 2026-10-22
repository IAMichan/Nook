import { describe, expect, it } from "vitest";
import { conversationGroups, recoverDeletedConversation } from "./conversation-list";
import type { ConversationSummary } from "./types";

const item = (id: string, patch: Partial<ConversationSummary> = {}): ConversationSummary => ({
  id, title: id, updated: "2026-10-22T12:00:00Z", status: "idle", preview: "A message", pinned: false, archived: false, ...patch,
});

describe("conversation list", () => {
  it("groups pins and recent conversations without hiding empty pins or the active draft", () => {
    const rows = [item("old", { updated: "2026-10-20T12:00:00Z" }), item("pin", { pinned: true, preview: "" }), item("new"), item("draft", { preview: "" }), item("hidden", { preview: "" }), item("archive", { archived: true })];
    expect(conversationGroups(rows, "draft").map((group) => [group.title, group.items.map((row) => row.id)])).toEqual([
      ["Pinned", ["pin"]], ["Recent", ["new", "draft", "old"]],
    ]);
    expect(rows[0].id).toBe("old");
  });

  it("keeps an unaffected active conversation", async () => {
    const selected: string[] = [];
    const state = { activeId: "keep", active: null, nooks: [item("keep")], refreshList: async () => {}, select: async (id: string) => { selected.push(id); } };
    await recoverDeletedConversation(state, "remove");
    expect(state.activeId).toBe("keep");
    expect(selected).toEqual([]);
  });

  it("opens an existing survivor including an empty draft", async () => {
    const selected: string[] = [];
    const state = { activeId: "remove", active: null, nooks: [item("draft", { preview: "" })], refreshList: async () => {}, select: async (id: string) => { selected.push(id); } };
    await recoverDeletedConversation(state, "remove");
    expect(selected).toEqual(["draft"]);
  });

  it("leaves the last deletion empty without creating a Nook", async () => {
    const state = { activeId: "remove", active: null, nooks: [], refreshList: async () => {}, select: async () => { throw new Error("Nothing to select"); } };
    await recoverDeletedConversation(state, "remove");
    expect(state.activeId).toBeNull();
    expect(state.active).toBeNull();
  });

  it("preserves a selection made during refresh", async () => {
    const state = { activeId: "remove", active: null, nooks: [item("first"), item("chosen")], refreshList: async () => { state.activeId = "chosen"; }, select: async () => { throw new Error("Do not replace the selection"); } };
    await recoverDeletedConversation(state, "remove");
    expect(state.activeId).toBe("chosen");
  });

  it("reports refresh failures after clearing the removed conversation", async () => {
    const state = { activeId: "remove", active: null, nooks: [item("remove")], refreshList: async () => { throw new Error("Offline"); }, select: async () => {} };
    await expect(recoverDeletedConversation(state, "remove")).rejects.toThrow("Offline");
    expect(state.activeId).toBeNull();
  });
});
