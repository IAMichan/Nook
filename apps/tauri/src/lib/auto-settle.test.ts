import { describe, expect, it } from "vitest";
import { emptyState, unsettle, type InboxRow } from "./agent-inbox";
import {
  autoSettle,
  cleanedRules,
  cleanedSettleActions,
  decide,
  DEFAULT_RULES,
  DEFAULT_SETTLE_ACTIONS,
  planSettleActions,
  type SettleableRow,
} from "./auto-settle";

const DAY = 86_400_000;
const now = 100 * DAY;
const row = (id: string, daysAgo: number, attention: InboxRow["attention"] = "idle", extra: Partial<SettleableRow> = {}): SettleableRow =>
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

  it("cleans stored rules to 1…30 days and preserves pull-request toggles", () => {
    expect(cleanedRules(null)).toEqual(DEFAULT_RULES);
    expect(cleanedRules({ enabled: false, inactivityDays: 99 })).toEqual({
      ...DEFAULT_RULES,
      enabled: false,
      inactivityDays: 30,
    });
    expect(cleanedRules({ inactivityDays: 0 }).inactivityDays).toBe(1);
    expect(cleanedRules({ settleOnMergedPullRequest: false }).settleOnClosedPullRequest).toBe(false);
    expect(cleanedRules({ settleOnMergedPullRequest: false, settleOnClosedPullRequest: true }).settleOnClosedPullRequest).toBe(true);
  });

  it("settles merged or closed pull requests immediately and keeps open pull requests when configured (AG-110)", () => {
    expect(decide(row("pr-merged", 1, "idle", { pullRequest: "merged" }), emptyState(), DEFAULT_RULES, {}, now)).toEqual({ settle: true });
    expect(decide(row("pr-closed", 1, "idle", { pullRequest: "closed" }), emptyState(), DEFAULT_RULES, {}, now)).toEqual({ settle: true });
    expect(
      decide(
        row("pr-open", 15, "idle", { pullRequest: "open" }),
        emptyState(),
        { ...DEFAULT_RULES, keepWithOpenPullRequest: true },
        {},
        now,
      ),
    ).toEqual({ settle: false, reason: "openPullRequest" });
  });

  it("plans settle actions only when no other unsettled session shares the folder (AG-111)", () => {
    expect(cleanedSettleActions(null)).toEqual(DEFAULT_SETTLE_ACTIONS);
    const actions = { stopDevServersOnSettle: true, closeIdleTerminalsOnSettle: true, settleCommand: " git status " };
    expect(planSettleActions("/repo/a/", ["/repo/b"], actions)).toEqual({
      folder: "/repo/a",
      stopDevServers: true,
      closeIdleTerminals: true,
      command: "git status",
    });
    expect(planSettleActions("/repo/a", ["/repo/a/"], actions)).toBeNull();
    expect(planSettleActions("/repo/a", [], DEFAULT_SETTLE_ACTIONS)).toBeNull();
  });
});

