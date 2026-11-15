import { describe, expect, it } from "vitest";
import {
  emptyCache, kept, MAX_CHATS, MAX_LINES, readCache, recordChatLines, recordConversations, recordInbox, recordInboxLines,
  recordSessions, recordTimeline,
} from "./companion-cache";
import type { ChatLine, InboxChatDigest, InboxLine, SessionDigest, TimelineEntry } from "./companion";

const session = (id: string) => ({ id, title: id, agent: "Claude", attention: "idle", folder: "app", updated: 0, excerpt: "", items: [] }) as unknown as SessionDigest;
const line = (id: string): InboxLine => ({ id, text: id, date: 0, sender: "", fromMe: false, reactions: [] });

describe("the companion's cache", () => {
  it("keeps a list, never an older one over a newer one, and writes only when worth it", () => {
    const c = emptyCache();
    expect(recordSessions(c, [session("new")], 120)).toBe(true);
    expect(recordSessions(c, [session("old")], 60)).toBe(false);
    expect(c.sessions.map((s) => s.id)).toEqual(["new"]);
    expect(recordSessions(c, [session("new")], 130), "the same list within the minute").toBe(false);
    expect(c.saved).toBe(130);
    expect(recordSessions(c, [session("new")], 185), "a new minute for Last updated").toBe(true);
  });

  it("keeps chats settled, so they read without the computer", () => {
    const c = emptyCache();
    recordConversations(c, [{ id: "c1", title: "Plan", updated: 1, busy: true, waiting: false, preview: "" }]);
    expect(c.conversations[0].busy).toBe(false);
    const answer: ChatLine = { id: "l1", fromNook: true, text: "Half", date: 1, streaming: true, status: "Looking…", failed: false, onMac: false };
    recordChatLines(c, "c1", [answer], 10);
    expect(kept(c.chatLines, "c1")?.[0]).toMatchObject({ streaming: false, status: "" });
    expect(recordChatLines(c, "c1", [answer], 5), "never older over newer").toBe(false);
    const chat = { id: "w1", app: "whatsapp", appName: "WhatsApp", name: "Sam", preview: "", last: 1, unread: 0, canSend: true, waitsInApp: false, typing: [{ name: "", kind: "text" }] } as InboxChatDigest;
    recordInbox(c, [chat]);
    expect(c.inbox[0].typing).toBeUndefined();
  });

  it("keeps the last chats that were open, with their newest messages", () => {
    const c = emptyCache();
    for (let i = 0; i <= MAX_CHATS; i++) recordInboxLines(c, `w${i}`, [line("m")], 1);
    expect(c.inboxLines).toHaveLength(MAX_CHATS);
    expect(kept(c.inboxLines, "w0")).toBeNull();
    recordInboxLines(c, "w9", Array.from({ length: MAX_LINES + 20 }, (_, i) => line(`m${i}`)), 2);
    expect(kept(c.inboxLines, "w9")).toHaveLength(MAX_LINES);
    const newest = kept(c.inboxLines, "w9") ?? [];
    expect(newest[newest.length - 1]?.id).toBe(`m${MAX_LINES + 19}`);
    const entry = { id: "e1", kind: "assistant", text: "hi", date: 0 } as TimelineEntry;
    expect(recordTimeline(c, "s1", [entry], 1)).toBe(true);
    expect(recordTimeline(c, "s1", [entry], 2), "unchanged").toBe(false);
  });

  it("reads what an older version wrote, or nothing at all, without failing", () => {
    expect(readCache({ saved: 5, sessions: [session("s")] }).inbox).toEqual([]);
    expect(readCache({ saved: 5, sessions: [session("s")] }).sessions).toHaveLength(1);
    expect(readCache("nonsense")).toEqual(emptyCache());
  });
});
