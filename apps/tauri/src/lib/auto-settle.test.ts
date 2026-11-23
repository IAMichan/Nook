import { describe, expect, it } from "vitest";
import { emptyState, unsettle, type InboxRow } from "./agent-inbox";
import { autoSettle, cleanedRules, decide, DEFAULT_RULES } from "./auto-settle";

const DAY = 86_400_000;
const now = 100 * DAY;
const row = (id: string, daysAgo: number, attention: InboxRow["attention"] = "idle", extra: Partial<InboxRow> = {}): InboxRow =>
  ({ id, title: id, project: "p", attention, lastActivity: now - daysAgo * DAY, ...extra });
const rules = { enabled: true, inactivityDays: 7 };

describe("auto-settle", () => {
  it("settles quiet rows older than the days, and only those", () => {
    const rows = [row("old", 8), row("fresh", 2), row("ask", 30, "approval"), row("input", 30, "input"), row("busy", 30, "working"), row("bg", 30, "idle", { hasBackgroundWork: true })];
    const r = autoSettle(rows, emptyState(), rules, {}, now);
    expect(r.settled).toEqual(["old"]);
    expect(r.state.settled).toEqual(["old"]);
    expect(r.autoSettled).toEqual({ old: now - 8 * DAY });
  });

  it("never settles pinned or snoozed rows; a woken snooze counts from its end", () => {
    const state = { ...emptyState(), pinned: ["pin"], snoozed: { nap: now + DAY, woke: now - 2 * DAY } };
    expect(decide(row("pin", 30), state, rules, {}, now)).toEqual({ settle: false, reason: "pinned" });
    expect(decide(row("nap", 30), state, rules, {}, now)).toEqual({ settle: false, reason: "snoozed" });
    expect(decide(row("woke", 30), state, rules, {}, now)).toEqual({ settle: false, reason: "recentActivity" });
  });

  it("does nothing when off", () => {
    expect(autoSettle([row("old", 30)], emptyState(), { ...rules, enabled: false }, {}, now).settled).toEqual([]);
  });

  it("does not settle again a row you reopened until it is active again", () => {
    const first = autoSettle([row("old", 8)], emptyState(), rules, {}, now);
    const reopened = unsettle(first.state, "old");
    expect(autoSettle([row("old", 8)], reopened, rules, first.autoSettled, now + 30 * DAY).settled).toEqual([]);
    // Something new happened in it, and then it went quiet again for longer than the days.
    const later = now + 30 * DAY;
    const active = { ...row("old", 0), lastActivity: now + DAY };
    expect(autoSettle([active], reopened, rules, first.autoSettled, later).settled).toEqual(["old"]);
  });

  it("cleans stored rules to 1…30 days", () => {
    expect(cleanedRules(null)).toEqual(DEFAULT_RULES);
    expect(cleanedRules({ enabled: false, inactivityDays: 99 })).toEqual({ enabled: false, inactivityDays: 30 });
    expect(cleanedRules({ inactivityDays: 0 }).inactivityDays).toBe(1);
  });
});
