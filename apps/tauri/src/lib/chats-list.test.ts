import { describe, expect, it } from "vitest";
import {
  abilitiesForApp,
  aggregatePeople,
  callDetail,
  callOf,
  callTitle,
  canForwardTo,
  clockOrDay,
  dayAndClock,
  entryAbilities,
  fillReceipts,
  firstLink,
  foldPersonName,
  formatBirthday,
  groupOf,
  inboxEntry,
  insertTag,
  isBirthdayToday,
  outgoingKindOfMedia,
  personTint,
  priorityBadge,
  readReceiptSummary,
  searchPeople,
  sections,
  shown,
  typingLine,
  typingTag,
  whatsAppEntry,
  type Bubble,
  type ChatEntry,
  type ReadMark,
} from "./chats-list";
import type { ChatSummary, WhatsAppConversation } from "./connectors";

const now = new Date(2026, 10, 19, 15, 0);
const at = (days: number, hours = 12) => new Date(2026, 10, 19 - days, hours, 0);

function entry(id: string, last: Date | null, unread = 0, listKind: ChatEntry["listKind"] = "chats", read?: ReadMark, account: string | null = null): ChatEntry {
  return {
    id, key: `whatsapp#${id}`, app: "whatsapp", name: id, isGroup: false, listKind, last, preview: `hello ${id}`, ticks: null, unread,
    read: read ?? (unread ? "unread" : "read"), lastIsMine: false, account, sends: true, mutedInApp: false,
  };
}

function bubble(id: string, fromMe: boolean, over: Partial<Bubble> = {}): Bubble {
  return {
    id, sender: "", text: `msg ${id}`, date: at(0, 12).toISOString(), fromMe,
    media: { kind: "none" }, receipt: null, edited: false, deleted: false, replyTo: null, reactions: [], versions: [],
    readAt: null, readBy: [], readers: [],
    ...over,
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

  it("puts the chat named after the search above the chats that only mention it", () => {
    const arjan = { ...entry("arjan", at(0, 14)), name: "Arjan", preview: "Dan controleren Noah en ik" };
    const noah = { ...entry("noah", at(0, 10)), name: "Noah" };
    const noahs = { ...entry("noahs", at(0, 9)), name: "Team Noahs" };
    const list = shown([arjan, noahs, noah], { view: "all", app: null, kind: "chats", query: "noah" });
    expect(list.map((e) => e.id)).toEqual(["noah", "noahs", "arjan"]);
    expect(sections(list, now, [], "noah").map((s) => [s.group, s.entries.map((e) => e.id)])).toEqual([["named", ["noah", "noahs"]], ["today", ["arjan"]]]);
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
  it("reads an app's call line as a call, as the Mac does", () => {
    const missed = callOf("Missed voice call")!;
    expect(missed).toEqual({ video: false, missed: true, outgoing: null, seconds: null });
    expect(callTitle(missed, false)).toBe("Missed voice call");
    expect(callDetail(missed, true)).toBe("Outgoing · No answer");
    const video = callOf("Videoanruf 2:13")!;
    expect([video.video, video.seconds]).toEqual([true, 133]);
    expect(callDetail(video, false)).toBe("Incoming · 2:13");
    expect(callOf("Can you call me?")).toBeNull();
    expect(callOf("call")).toBeNull();
    expect(firstLink("see https://example.com/a, ok")).toBe("https://example.com/a");
    expect(firstLink("http://localhost")).toBeNull();
  });

  it("fills ticks on older outgoing messages and propagates group readers (CH-54)", () => {
    const m1 = bubble("1", true, { receipt: null });
    const m2 = bubble("2", true, { receipt: "pending" });
    const m3 = bubble("3", true, { receipt: "read", readAt: new Date(2026, 10, 19, 14, 5).toISOString(), readBy: ["Anna"] });
    const reply = bubble("4", false, { sender: "Bo", date: new Date(2026, 10, 19, 14, 10).toISOString() });

    const priv = fillReceipts([m1, m2, m3], true);
    expect(priv.map((b) => b.receipt)).toEqual(["read", "read", "read"]);

    const privReply = fillReceipts([bubble("s", true, { receipt: "sent" }), bubble("r", false)], true);
    expect(privReply[0].receipt).toBe("delivered");
    expect(privReply[1].receipt).toBeNull();

    const grp = fillReceipts([m1, m3, reply], false);
    expect(grp[0].readBy).toEqual(expect.arrayContaining(["Anna", "Bo"]));
    expect(grp[1].readBy).toEqual(expect.arrayContaining(["Anna", "Bo"]));
    expect(readReceiptSummary(grp[0], true, now, "en-GB")).toBe("Read by Bo and Anna");
    expect(readReceiptSummary(priv[2], false, now, "en-GB")).toBe("Read 14:05");
    expect(dayAndClock(at(1, 9).toISOString(), now, "en-GB")).toBe("Yesterday 09:00");
  });

  it("formats typing indicator lines cleanly for private and group chats (CH-54)", () => {
    expect(typingLine([], false)).toBeNull();
    expect(typingLine(["Anna"], false)).toBe("Anna is typing…");
    expect(typingLine([""], false, "Anna")).toBe("Anna is typing…");
    expect(typingLine([""], true)).toBe("Typing…");
    expect(typingLine(["Anna", "Bo"], true)).toBe("Anna and Bo are typing…");
    expect(typingLine(["Anna", "Bo", "Cy"], true)).toBe("Anna and 2 others are typing…");
  });

  it("aggregates, searches, and formats birthdays for People (CH-33)", () => {
    const entries: ChatEntry[] = [
      { ...entry("31612345678@s.whatsapp.net", at(0, 14), 2), name: "Ánna Bakker", app: "whatsapp", key: "whatsapp#31612345678@s.whatsapp.net", handle: "+31612345678" },
      { ...entry("tg-anna", at(1, 10), 1), name: "Anna Bakker", app: "telegram", key: "telegram#tg-anna", preview: "See you Friday" },
      { ...entry("grp", at(0, 15), 5), name: "Design Team", isGroup: true, app: "slack", key: "slack#grp" },
      { ...entry("sig-bo", at(2, 9), 0), name: "Bo", app: "signal", key: "signal#sig-bo" },
    ];
    expect(foldPersonName("  Ánna\u200B  Bakker ")).toBe("anna bakker");
    const people = aggregatePeople(entries);
    expect(people.map((p) => p.name)).toEqual(["Ánna Bakker", "Bo"]);
    expect(people[0].apps).toEqual(["whatsapp", "telegram"]);
    expect(people[0].unread).toBe(3);

    const notes = { "whatsapp#31612345678@s.whatsapp.net": { note: "Loves espresso", birthday: "11-19" } };
    expect(searchPeople(people, "espresso", notes).map((p) => p.name)).toEqual(["Ánna Bakker"]);
    expect(searchPeople(people, "signal", notes).map((p) => p.name)).toEqual(["Bo"]);
    expect(isBirthdayToday("11-19", now)).toBe(true);
    expect(isBirthdayToday("04-12", now)).toBe(false);
    expect(formatBirthday("02-29", "en-GB")).toMatch(/29/);
  });

  it("matches people across apps by phone key, WhatsApp JID, and email regardless of display name (CH-08)", () => {
    const entries: ChatEntry[] = [
      { ...entry("wa-1", at(0, 14), 1), name: "Anna de Vries", app: "whatsapp", key: "whatsapp#31612345678@s.whatsapp.net", handle: "31612345678:3@s.whatsapp.net" },
      { ...entry("tg-1", at(1, 10), 2), name: "Anna", app: "telegram", key: "telegram#1", handle: "0612345678" },
      { ...entry("sl-1", at(0, 12), 0), name: "Anna V.", app: "slack", key: "slack#1", handle: "Anna@Contoso.com" },
      { ...entry("tm-1", at(2, 9), 0), name: "Anna (Contoso)", app: "teams", key: "teams#1", handle: "anna@contoso.com" },
      { ...entry("sig-1", at(3, 8), 0), name: "Ｊｏｓé", app: "signal", key: "signal#1" },
    ];
    expect(foldPersonName("Anna-Marie  (Work)")).toBe("anna marie work");
    expect(foldPersonName("Ｊｏｓé")).toBe("jose");
    const people = aggregatePeople(entries);
    expect(people).toHaveLength(3);
    const byTel = people.find((p) => p.id === "tel:612345678");
    expect(byTel?.apps.sort()).toEqual(["telegram", "whatsapp"]);
    expect(byTel?.unread).toBe(3);
    const byMail = people.find((p) => p.id === "mail:anna@contoso.com");
    expect(byMail?.apps.sort()).toEqual(["slack", "teams"]);
    expect(people.find((p) => p.id === "name:jose")?.name).toBe("Ｊｏｓé");
  });

  it("derives per-app ChatAbilities and respects pinned/archived flags (CH-58)", () => {
    const wa = abilitiesForApp("whatsapp", true, { pinned: true });
    expect(wa.send).toBe(true);
    expect(wa.markRead).toBe(true);
    expect(wa.deleteForMe).toBe(true);
    expect(wa.pin).toBe(false);
    expect(wa.mute).toBe(false);
    expect(wa.archive).toBe(false);
    expect(wa.pinned).toBe(true);

    const tg = abilitiesForApp("telegram", true, { muted: true, archived: true });
    expect(tg.pin).toBe(true);
    expect(tg.mute).toBe(true);
    expect(tg.archive).toBe(true);
    expect(tg.markUnread).toBe(true);
    expect(tg.deleteForMe).toBe(false);
    expect(tg.muted).toBe(true);
    expect(tg.archived).toBe(true);

    const readonly = abilitiesForApp("signal", false);
    expect(readonly.send).toBe(false);
    expect(readonly.sends).toEqual([]);
    expect(readonly.pin).toBe(false);

    const pinnedEntry = { ...entry("p", at(2)), pinned: true };
    const archivedEntry = { ...entry("arch", at(0)), archived: true };
    const active = [entry("b", at(0)), pinnedEntry, archivedEntry];
    expect(shown(active, { view: "all", app: null, kind: "chats", query: "" }).map((e) => e.id)).toEqual(["b", "p"]);
    expect(shown(active, { view: "all", app: null, kind: "chats", query: "arch" }).map((e) => e.id)).toEqual(["arch"]);
    expect(sections([entry("b", at(0)), pinnedEntry], now).map((s) => [s.group, s.entries.map((e) => e.id)])).toEqual([
      ["pinned", ["p"]],
      ["today", ["b"]],
    ]);
  });

  it("checks media outgoing kinds and forward target capabilities (CH-48)", () => {
    expect(outgoingKindOfMedia({ kind: "image", name: "photo.jpg" })).toBe("photo");
    expect(outgoingKindOfMedia({ kind: "image", name: "funny.GIF" })).toBe("gif");
    expect(outgoingKindOfMedia({ kind: "video" })).toBe("video");
    expect(outgoingKindOfMedia({ kind: "voice" })).toBe("voice");
    expect(outgoingKindOfMedia({ kind: "document", name: "report.pdf" })).toBe("file");
    expect(outgoingKindOfMedia({ kind: "sticker" })).toBeNull();
    expect(outgoingKindOfMedia({ kind: "none" })).toBeNull();

    const writable = entry("w", at(0));
    const readOnly = { ...entry("r", at(0)), sends: false };
    const textOnly = { ...entry("t", at(0)), abilities: { ...entryAbilities(writable), sends: [] } };

    expect(canForwardTo(writable, "hello", null)).toBe(true);
    expect(canForwardTo(writable, "", "photo")).toBe(true);
    expect(canForwardTo(writable, "   ", null)).toBe(false);
    expect(canForwardTo(readOnly, "hello", null)).toBe(false);
    expect(canForwardTo(textOnly, "hello", null)).toBe(true);
    expect(canForwardTo(textOnly, "caption", "photo")).toBe(false);
  });

  it("maps scored notice priorities to compact badges (CH-64)", () => {
    expect(priorityBadge(null)).toBeNull();
    expect(priorityBadge({ score: 15, level: "normal", raises: false, reasons: [] })).toBeNull();
    expect(priorityBadge({ score: 50, level: "elevated", raises: false, reasons: ["question"] })).toBeNull();

    expect(priorityBadge({ score: 55, level: "elevated", raises: true, reasons: ["question"] })).toEqual({
      label: "Question",
      tone: "elevated",
      icon: "message-circle-question",
    });
    expect(priorityBadge({ score: 70, level: "elevated", raises: true, reasons: ["directMention"] })).toEqual({
      label: "Mentioned",
      tone: "elevated",
      icon: "bell-dot",
    });
    expect(priorityBadge({ score: 90, level: "urgent", raises: true, reasons: ["question", "urgentCue"] })).toEqual({
      label: "Urgent",
      tone: "urgent",
      icon: "triangle-alert",
    });
  });
});

