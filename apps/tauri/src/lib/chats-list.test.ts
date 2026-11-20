import { describe, expect, it } from "vitest";
import { clockOrDay, groupOf, inboxEntry, insertTag, typingTag, personTint, sections, shown, whatsAppEntry, type ChatEntry, type ReadMark } from "./chats-list";
import type { ChatSummary, WhatsAppConversation } from "./connectors";

const now = new Date(2026, 10, 19, 15, 0);
const at = (days: number, hours = 12) => new Date(2026, 10, 19 - days, hours, 0);

function entry(id: string, last: Date | null, unread = 0, listKind: ChatEntry["listKind"] = "chats", read?: ReadMark, account: string | null = null): ChatEntry {
  return {
    id, key: `whatsapp#${id}`, app: "whatsapp", name: id, isGroup: false, listKind, last, preview: `hello ${id}`, ticks: null, unread,
    read: read ?? (unread ? "unread" : "read"), lastIsMine: false, account, sends: true, mutedInApp: false,
  };
}

describe("the Chats list", () => {
  it("groups chats by when they last moved, as the Mac does", () => {
    expect(groupOf(at(0, 9), now)).toBe("today");
    expect(groupOf(at(1), now)).toBe("yesterday");
    expect(groupOf(at(5), now)).toBe("week");
    expect(groupOf(at(20), now)).toBe("month");
    expect(groupOf(at(40), now)).toBe("earlier");
    expect(groupOf(null, now)).toBe("earlier");
  });

  it("shows the chosen view and tab, newest first, and searches every view", () => {
    const all = [entry("a", at(2)), entry("b", at(0), 2), entry("c", at(1)), entry("s", at(0), 1, "status")];
    expect(shown(all, { view: "all", app: null, kind: "chats", query: "" }).map((e) => e.id)).toEqual(["b", "c", "a"]);
    expect(shown(all, { view: "unread", app: null, kind: "chats", query: "" }).map((e) => e.id)).toEqual(["b"]);
    expect(shown(all, { view: "read", app: null, kind: "chats", query: "" }).map((e) => e.id)).toEqual(["c", "a"]);
    expect(shown(all, { view: "unread", app: null, kind: "chats", query: "hello a" }).map((e) => e.id)).toEqual(["a"]);
    expect(shown(all, { view: "all", app: null, kind: "status", query: "" }).map((e) => e.id)).toEqual(["s"]);
  });

  it("puts the rows in their groups in order, the pinned ones on top", () => {
    const list = [entry("b", at(0)), entry("c", at(1)), entry("a", at(2))];
    expect(sections(list, now).map((s) => [s.group, s.entries.length])).toEqual([["today", 1], ["yesterday", 1], ["week", 1]]);
    expect(sections(list, now, ["whatsapp#a"]).map((s) => [s.group, s.entries.map((e) => e.id)])).toEqual([["pinned", ["a"]], ["today", ["b"]], ["yesterday", ["c"]]]);
  });

  it("tells read in Nook from read everywhere, and filters by account", () => {
    const all = [entry("a", at(0), 0, "chats", "readInNook", "Work"), entry("b", at(1), 0, "chats", "read", "Home")];
    expect(shown(all, { view: "readInNook", app: null, kind: "chats", query: "" }).map((e) => e.id)).toEqual(["a"]);
    expect(shown(all, { view: "read", app: null, kind: "chats", query: "" }).map((e) => e.id)).toEqual(["b"]);
    expect(shown(all, { view: "all", app: "whatsapp", account: "Home", kind: "chats", query: "" }).map((e) => e.id)).toEqual(["b"]);
  });

  it("reads any app's chat from the shared inbox into a row", () => {
    const s: ChatSummary = {
      key: "telegram#42", app: "telegram", name: "Book club", kind: "group", account: "me@tg", read: { state: "unread", count: 3 },
      last: { id: "m", sender: "Eva", text: "", date: at(0).toISOString(), fromMe: false, media: { kind: "image" } },
      activity: at(0).toISOString(), members: 5, mutedInApp: false, sends: false,
    };
    const e = inboxEntry(s);
    expect([e.id, e.key, e.app, e.isGroup, e.unread, e.read, e.account, e.sends]).toEqual(["42", "telegram#42", "telegram", true, 3, "unread", "me@tg", false]);
    expect(e.preview).toBe("Eva: Photo");
    expect(inboxEntry({ ...s, read: { state: "readInNook" } }).read).toBe("readInNook");
    expect(inboxEntry({ ...s, last: { ...s.last!, deleted: true } }).preview).toBe("Eva: This message was deleted");
  });

  it("says a time today and a day before", () => {
    expect(clockOrDay(new Date(2026, 10, 19, 9, 5), now, "en-GB")).toBe("09:05");
    expect(clockOrDay(at(1), now, "en-GB")).toBe("Yesterday");
    expect(clockOrDay(null, now, "en-GB")).toBe("");
  });

  it("gives each person the same color every time", () => {
    expect(personTint("Anna")).toBe(personTint("anna"));
    expect(personTint("Anna")).toMatch(/^var\(--(mint|blue|violet|music)\)$/);
  });

  it("reads a WhatsApp chat into a row: who wrote last in a group, your ticks, status apart", () => {
    const c: WhatsAppConversation = {
      id: "g", name: "Team", isGroup: true, kind: "group", unread: 1, lastActivity: at(0).toISOString(),
      messages: [{ id: "1", chat: "g", senderName: "Lisa", text: "Hi", media: { kind: "none" }, date: at(0).toISOString(), fromMe: false }],
    };
    const e = whatsAppEntry(c);
    expect(e.preview).toBe("Lisa: Hi");
    expect(e.ticks).toBeNull();
    expect(whatsAppEntry({ ...c, kind: "status" }).listKind).toBe("status");
    const mine = whatsAppEntry({ ...c, messages: [{ ...c.messages[0], fromMe: true, receipt: "read" }] });
    expect(mine.preview).toBe("Hi");
    expect(mine.ticks).toBe("read");
    const withAccount = whatsAppEntry(c, {
      key: "whatsapp#g", app: "whatsapp", name: "Team", kind: "group", account: "Work",
      read: { state: "unread", count: 1 }, last: null, activity: at(0).toISOString(),
      members: 2, mutedInApp: false, sends: true,
    });
    expect(withAccount.account).toBe("Work");
  });
  it("finds the @name being typed and puts the chosen person in its place", () => {
    expect(typingTag("hi @An")).toBe("An");
    expect(typingTag("@")).toBe("");
    expect(typingTag("mail me@home")).toBeNull();
    expect(typingTag("hi @Anna done")).toBeNull();
    expect(insertTag("hi @An", "Anna Bakker")).toBe("hi @Anna Bakker ");
  });
});
