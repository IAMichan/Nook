import { describe, expect, it } from "vitest";
import {
  applyConversation, applyTimeline, attentionWord, resumePoint, parseCompanionLink, widgetData, parseNotificationAction, shortcutSessions, canStop, FileAssembly, newerMac, snoozeRange, versionNotice, filterInbox, groupSessions, has, looksLikePairingLink, matchesSession, may, needingYou, resetsIn,
  sendNotice, sessionActions, sortSessions, tabsFor, unreadChats, type InboxChatDigest, type SessionDigest,
  chatKinds, chatsGroup, filterChats, groupChats, mergeInboxLines, pollChoice, pollVoting, prependInboxLines, readState, type InboxLine, type InboxPoll,
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
    // Until the limit resets needs the moment.
    expect(sessionActions(s)).toEqual(["rename", "snoozeHour", "snoozeUntil", "archive"]);
    expect(sessionActions({ ...s, limitResetsAt: 100 })).toEqual(["rename", "snoozeHour", "snoozeLimitReset", "snoozeUntil", "archive"]);
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

  it("applies a live update to the conversation as TimelineDelta does", () => {
    const e = (id: string, text = id) => ({ id, kind: "assistant" as const, text, date: 0, failed: false });
    const old = [e("1"), e("2"), e("3", "partial")];
    expect(applyTimeline(old, [e("3", "whole"), e("4")], "2")?.map((x) => x.text)).toEqual(["1", "2", "whole", "4"]);
    expect(applyTimeline(old, [e("9")], undefined)?.map((x) => x.id)).toEqual(["9"]);
    expect(applyTimeline(old, [e("4")], "missing")).toBeNull();
    expect(applyTimeline(null, [e("4")], "2")).toBeNull();
    expect(applyTimeline(old, [e("4")], "3", 2)?.map((x) => x.id)).toEqual(["3", "4"]);
  });

  it("follows Nook's answer as it writes, as ConversationDelta does", () => {
    const line = (id: string, text: string, streaming = false) =>
      ({ id, fromNook: id !== "q", text, date: 100, streaming, status: "", failed: false, onMac: false });
    const old = [line("q", "Wat staat er vandaag?"), line("a", "Je hebt om 10:00", true)];
    // Only Nook's new words come, counted in code points (an emoji with a skin tone is two).
    const words = applyConversation(old, { messageAppend: { id: "a", at: 16, text: " een call 👋🏽", streaming: true, status: "" } });
    expect(words?.[1].text).toBe("Je hebt om 10:00 een call 👋🏽");
    const done = applyConversation(words, { messageAppend: { id: "a", at: 16 + Array.from(" een call 👋🏽").length, text: ".", streaming: false, status: "" } });
    expect(done?.[1]).toMatchObject({ text: "Je hebt om 10:00 een call 👋🏽.", streaming: false });
    // An update that does not build on what the phone has is refused: the phone asks again.
    expect(applyConversation(old, { messageAppend: { id: "a", at: 3, text: "x", streaming: true, status: "" } })).toBeNull();
    expect(applyConversation(old, { messageAppend: { id: "b", at: 16, text: "x", streaming: true, status: "" } })).toBeNull();
    expect(applyConversation(null, { messageAppend: { id: "a", at: 0, text: "x", streaming: true, status: "" } })).toBeNull();
    // New messages go after the last one both have; none named: the conversation whole.
    const tail = applyConversation(done, { messages: [line("q2", "En morgen?"), line("a2", "", true)], messagesAfter: "a" });
    expect(tail?.map((l) => l.id)).toEqual(["q", "a", "q2", "a2"]);
    expect(applyConversation(old, { messages: [line("z", "")], messagesAfter: "gone" })).toBeNull();
    expect(applyConversation(old, { messages: [line("z", "")] })?.map((l) => l.id)).toEqual(["z"]);
    expect(applyConversation(old, {})).toBe(old);
    // After a reconnect the phone names its last finished message.
    expect(resumePoint(tail)).toBe("q2");
    expect(resumePoint([])).toBeUndefined();
  });

  it("says which side to update, as CompanionCompatibility", () => {
    expect(versionNotice({ macVersion: null, oldestPhone: null })).toBe("macBehind");
    expect(versionNotice({ macVersion: 3, oldestPhone: 1 })).toBeNull();
    expect(versionNotice({ macVersion: 4, oldestPhone: 4 })).toBe("phoneTooOld");
    expect(versionNotice({ macVersion: 4, oldestPhone: 2 })).toBe("phoneBehind");
    expect(newerMac({ features: ["start", "teleport"] })).toBe(true);
    expect(newerMac({ features: ["start"] })).toBe(false);
  });

  it("puts a file together from its pieces in order", () => {
    const a = new FileAssembly();
    expect(a.add({ path: "x", offset: 0, total: 6, data: btoa("abc") })).toBe(true);
    expect(a.add({ path: "x", offset: 0, total: 6, data: btoa("abc") })).toBe(false);
    expect(a.add({ path: "x", offset: 3, total: 7, data: btoa("def") })).toBe(false);
    expect(a.add({ path: "x", offset: 3, total: 6, data: btoa("def") })).toBe(true);
    expect(a.done).toBe(true);
    const r = snoozeRange(0);
    expect(r.min).toBe(90_000);
  });

  it("reads what a notification asks the app to do", () => {
    expect(parseNotificationAction('{"action":"allow","mac":"m","session":"S1","item":"p1","text":null}')).toEqual({ action: "allow", mac: "m", session: "S1", item: "p1", text: null });
    expect(parseNotificationAction('{"action":"reply","mac":"m","session":"S1","item":null,"text":"go on"}')?.text).toBe("go on");
    expect(parseNotificationAction('{"action":"format","session":"S1"}')).toBeNull();
    expect(parseNotificationAction("nonsense")).toBeNull();
  });

  it("reads the icon's shortcuts and offers the sessions that need you", () => {
    expect(parseCompanionLink("nook://companion/new")).toEqual({ kind: "new" });
    expect(parseCompanionLink("nook://companion/session?id=S1&mac=m")).toEqual({ kind: "session", id: "S1", mac: "m" });
    expect(parseCompanionLink("nook://companion/format")).toBeNull();
    const list = shortcutSessions([session("a", "working", 3), session("b", "approval", 1), session("c", "failed", 2), session("d", "input", 4)], "m");
    expect(list.map((s) => s.id)).toEqual(["b", "d"]);
    expect(list[0].url).toBe("nook://companion/session?id=b&mac=m");
  });

  it("gives the widgets what works or waits, waiting first", () => {
    const d = widgetData([session("w", "working", 5), session("i", "idle", 9), session("a", "approval", 1)], [{ id: "x", agent: "Claude", account: "Work", limits: [{ label: "Week", percent: 41.6, resetsAt: 100 }] }], "m", 7);
    expect(d.agents.map((a) => [a.id, a.waiting])).toEqual([["a", true], ["w", false]]);
    expect(d.limits).toEqual([{ name: "Claude · Work · Week", percent: 42, resetsAt: 100 }]);
    expect(d.updatedAt).toBe(7);
  });

  it("groups the Chats list as the Mac does", () => {
    const now = new Date(2026, 10, 16, 15, 0).getTime();
    const at = (days: number, hour = 12) => { const d = new Date(now); d.setDate(d.getDate() - days); d.setHours(hour); return d.getTime() / 1000; };
    expect(chatsGroup({ last: at(0, 1) }, now)).toBe("today");
    expect(chatsGroup({ last: at(1, 23) }, now)).toBe("yesterday");
    expect(chatsGroup({ last: at(6) }, now)).toBe("week");
    expect(chatsGroup({ last: at(20) }, now)).toBe("month");
    expect(chatsGroup({ last: at(40) }, now)).toBe("earlier");
    expect(chatsGroup({ last: at(40), pinned: true }, now)).toBe("pinned");
    const groups = groupChats([chat("old", at(40)), chat("pin", at(3), 0, { pinned: true }), chat("a", at(0, 9)), chat("b", at(0, 10))], now);
    expect(groups.map((g) => [g.group, g.chats.map((c) => c.id)])).toEqual([["pinned", ["pin"]], ["today", ["b", "a"]], ["earlier", ["old"]]]);
  });

  it("filters the Chats list by read state, app and list", () => {
    const list = [
      chat("new", 1, 2),
      chat("nook", 2, 0, { waitsInApp: true }),
      chat("read", 3, 0, { app: "telegram", appName: "Telegram" }),
      chat("status", 4, 1, { kind: "status" }),
      chat("channel", 5, 0, { kind: "channels" }),
    ];
    expect(readState(list[0])).toBe("unread");
    expect(readState(list[1])).toBe("readInNook");
    expect(readState(list[2])).toBe("read");
    expect(filterChats(list, {}).map((c) => c.id)).toEqual(["new", "nook", "read"]);
    expect(filterChats(list, { read: "readInNook" }).map((c) => c.id)).toEqual(["nook"]);
    expect(filterChats(list, { app: "telegram" }).map((c) => c.id)).toEqual(["read"]);
    expect(filterChats(list, { app: "whatsapp", kind: "status" }).map((c) => c.id)).toEqual(["status"]);
    // Status and channels only with an app chosen, and they never count as unread chats.
    expect(filterChats(list, { kind: "status" }).map((c) => c.id)).toEqual(["new", "nook", "read"]);
    expect(chatKinds(list, "whatsapp")).toEqual(["chats", "status", "channels"]);
    expect(chatKinds(list, "telegram")).toEqual([]);
    expect(chatKinds(list, null)).toEqual([]);
    expect(unreadChats(list)).toBe(1);
  });

  it("keeps the messages you paged back to when the newest come again", () => {
    const line = (id: string): InboxLine => ({ id, text: id, date: 0, sender: "", fromMe: false, reactions: [] });
    const ids = (l: InboxLine[]) => l.map((x) => x.id);
    const kept = ["1", "2", "3", "4", "5"].map(line);
    expect(ids(mergeInboxLines(["3", "4", "5", "6"].map(line), kept))).toEqual(["1", "2", "3", "4", "5", "6"]);
    expect(ids(mergeInboxLines(["7"].map(line), kept))).toEqual(["7"]);
    expect(ids(mergeInboxLines(["1", "2"].map(line), kept))).toEqual(["1", "2"]);
    expect(ids(prependInboxLines(["a", "b", "1"].map(line), "1", kept))).toEqual(["a", "b", "1", "2", "3", "4", "5"]);
    expect(ids(prependInboxLines(["a"].map(line), "x", kept))).toEqual(ids(kept));
  });

  it("votes in a poll as the Mac does", () => {
    const poll: InboxPoll = { question: "When?", multiple: false, counted: true, options: [
      { text: "Mon", votes: 2, chosen: true }, { text: "Tue", votes: 1, chosen: false },
    ] };
    expect(pollChoice(poll, "Tue")).toEqual(["Tue"]);
    expect(pollChoice(poll, "Mon")).toEqual([]);
    expect(pollChoice({ ...poll, multiple: true }, "Tue")).toEqual(["Mon", "Tue"]);
    expect(pollVoting(poll, ["Tue"]).options).toEqual([{ text: "Mon", votes: 1, chosen: false }, { text: "Tue", votes: 2, chosen: true }]);
  });
});
