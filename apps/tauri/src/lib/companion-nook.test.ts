import { describe, expect, it } from "vitest";
import { nookGroup, nookMarkdown, nookMatches, nookSections, type ChatDigest } from "./companion";

// The Nook tab as on the Mac (`CompanionNookChatsTests` on the Mac).
describe("Nook's conversations", () => {
  const now = new Date(2026, 10, 23, 15, 0).getTime();
  const chat = (id: string, hoursAgo: number, extra: Partial<ChatDigest> = {}): ChatDigest => ({
    id, title: id, updated: now / 1000 - hoursAgo * 3600, busy: false, waiting: false, preview: "", ...extra,
  });

  it("groups by age as the Mac does", () => {
    expect(nookGroup(now / 1000 + 60, now)).toBe("today");
    expect(nookGroup(now / 1000 - 20 * 3600, now)).toBe("yesterday");
    expect(nookGroup(now / 1000 - 5 * 86400, now)).toBe("previousWeek");
    expect(nookGroup(now / 1000 - 30 * 86400, now)).toBe("older");
  });

  it("puts what asks for you on top, then pinned, then by age", () => {
    const s = nookSections([chat("busy", 0, { busy: true }), chat("pin", 200, { pinned: true }), chat("new", 1, { unread: true }),
      chat("today", 3), chat("old", 24 * 40), chat("run", 1, { scheduled: true })], false, now);
    expect(s.attention.map((c) => c.id)).toEqual(["busy", "new"]);
    expect(s.groups.map((g) => [g.group, g.chats.map((c) => c.id)])).toEqual([["pinned", ["pin"]], ["today", ["today"]], ["older", ["old"]]]);
    expect(nookSections([chat("run", 1, { scheduled: true })], true, now).groups[0].chats[0].id).toBe("run");
  });

  it("matches every word, ignoring case and accents", () => {
    expect(nookMatches({ title: "Café in Rome", preview: "" }, "cafe ROME")).toBe(true);
    expect(nookMatches({ title: "Café in Rome", preview: "" }, "rome paris")).toBe(false);
  });

  it("copies as the Mac writes it", () => {
    expect(nookMarkdown("Today", [{ fromNook: false, text: "Hi" }, { fromNook: true, text: "" }, { fromNook: true, text: "Lunch." }]))
      .toBe("# Today\n\n**You**\n\nHi\n\n**Nook**\n\nLunch.");
  });
});
