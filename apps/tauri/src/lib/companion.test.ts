import { describe, expect, it } from "vitest";
import {
  attentionWord, canStop, filterInbox, groupSessions, has, looksLikePairingLink, matchesSession, may, needingYou, resetsIn,
  sendNotice, sessionActions, sortSessions, tabsFor, unreadChats, type InboxChatDigest, type SessionDigest,
} from "./companion";

const session = (id: string, attention: string, updated: number, extra: Partial<SessionDigest> = {}): SessionDigest => ({
  id, title: id, agent: "Claude Code", attention, folder: "nook", updated, excerpt: "", items: [], ...extra,
});

const chat = (id: string, last: number, unread = 0, extra: Partial<InboxChatDigest> = {}): InboxChatDigest => ({
  id, app: "whatsapp", appName: "WhatsApp", name: id, preview: "", last, unread, canSend: true, waitsInApp: false, ...extra,
});

const approval = { id: "p", kind: "approval" as const, title: "rm", detail: "Bash", canAllow: false, options: [] };

describe("companion", () => {
  it("puts what needs you first, then the newest", () => {
    const sorted = sortSessions([session("a", "idle", 9), session("b", "approval", 1), session("c", "working", 5), session("d", "idle", 10)]);
    expect(sorted.map((s) => s.id)).toEqual(["b", "c", "d", "a"]);
  });

  it("names the states like the iPhone app", () => {
    expect(attentionWord("approval")).toBe("Waiting for approval");
    expect(attentionWord("whatever")).toBe("Idle");
    expect(canStop("working")).toBe(true);
    expect(canStop("ready")).toBe(false);
  });

  it("recognises a pairing link", () => {
    expect(looksLikePairingLink(" nook://pair?h=a&p=1&k=x ")).toBe(true);
    expect(looksLikePairingLink("https://pair?h=a")).toBe(false);
  });

  it("offers only the tabs the computer lists and allows", () => {
    // Nook on Windows or Linux lists no features: only Agents.
    expect(tabsFor({ features: [], scopes: null })).toEqual(["agents"]);
    expect(tabsFor({ features: ["home", "chat", "inbox"], scopes: null })).toEqual(["home", "agents", "chats"]);
    // Without the chats scope there is no Chats tab; Nook's chat alone still makes a Nook tab.
    expect(tabsFor({ features: ["chat", "inbox"], scopes: ["read", "nookChat"] })).toEqual(["home", "agents"]);
    expect(tabsFor({ features: ["chat"], scopes: ["read"] })).toEqual(["agents"]);
    expect(has({ features: ["start"] }, "start")).toBe(true);
    expect(may({ scopes: null }, "operate")).toBe(true);
    expect(may({ scopes: ["read"] }, "operate")).toBe(false);
  });

  it("groups the Agents list as the iPhone app does", () => {
    const g = groupSessions([session("w", "working", 3), session("q", "idle", 1, { items: [approval] }), session("r", "ready", 9), session("i", "idle", 2)]);
    expect(g.waiting.map((s) => s.id)).toEqual(["q"]);
    expect(g.working.map((s) => s.id)).toEqual(["w"]);
    expect(g.rest.map((s) => s.id)).toEqual(["r", "i"]);
    expect(needingYou([session("a", "idle", 1, { items: [approval] }), session("b", "working", 1)])).toBe(1);
  });

  it("finds a session by every word in its title, folder, branch or agent", () => {
    const s = session("Fix login", "idle", 1, { folder: "web", branch: "fix/login", agent: "Codex" });
    expect(matchesSession(s, "codex WEB")).toBe(true);
    expect(matchesSession(s, "login gemini")).toBe(false);
  });

  it("filters and orders the Chats list", () => {
    const chats = [chat("Ann", 1, 2), chat("Bob", 5), chat("Cas", 3, 1, { preview: "dinner?" })];
    expect(filterInbox(chats, "", false).map((c) => c.id)).toEqual(["Bob", "Cas", "Ann"]);
    expect(filterInbox(chats, "", true).map((c) => c.id)).toEqual(["Cas", "Ann"]);
    expect(filterInbox(chats, "dinner", false).map((c) => c.id)).toEqual(["Cas"]);
    expect(unreadChats(chats)).toBe(2);
  });

  it("offers the session actions the computer lists, in the Mac's order", () => {
    const s = session("s", "limited", 1, { actions: ["archive", "rename", "snoozeLimitReset", "snoozeUntil", "snoozeHour"] });
    // Until the limit resets needs the moment; snoozing to a picked time needs a picker this app lacks.
    expect(sessionActions(s)).toEqual(["rename", "snoozeHour", "archive"]);
    expect(sessionActions({ ...s, limitResetsAt: 100 })).toEqual(["rename", "snoozeHour", "snoozeLimitReset", "archive"]);
    expect(sessionActions(session("t", "idle", 1))).toEqual([]);
  });

  it("says where a message went and when a limit resets", () => {
    expect(sendNotice("queued")).toBe("Queued: after this turn.");
    expect(sendNotice("steered")).toBe("Passed into the running turn.");
    expect(sendNotice("sent")).toBeNull();
    const now = 1_000_000_000;
    expect(resetsIn(now / 1000 + 30 * 60, now)).toBe("in 30 min");
    expect(resetsIn(now / 1000 + 5 * 3600, now)).toBe("in 5 h");
    expect(resetsIn(now / 1000 - 10, now)).toBe("reset");
  });
});
