import { describe, expect, it } from "vitest";
import { isDone, latestRun, nookTasks, splitTasks, tabBadge, taskDetail, taskStatus } from "./nook-tasks";
import type { ConversationSummary } from "./types";
import { mayRunTask, type TaskView } from "./workspace/automation";

const now = new Date("2026-11-17T10:00:00");

function task(id: string, extra: Partial<TaskView> = {}): TaskView {
  return {
    id, title: id, prompt: `ask ${id}`, rule: { type: "fixedTime", hour: 9, minute: 0, weekdays: [] }, target: { type: "nook" },
    enabled: true, permission: "ask", lastRun: null, lastStatus: null, lastError: null, nextRun: null, lastSession: null,
    createdAt: now.toISOString(), running: false, webhookUrl: null, sessionTitle: null, ...extra,
  };
}

function run(id: string, taskId: string, status: ConversationSummary["status"], updated: string): ConversationSummary {
  return { id, title: id, updated, status, preview: "", pinned: false, archived: false, scheduledTask: taskId };
}

describe("Nook's scheduled tasks", () => {
  it("lists only Nook's tasks, the next to run first, filtered by name or request", () => {
    const tasks = [
      task("later", { nextRun: "2026-11-18T09:00:00" }),
      task("agent", { target: { type: "existingSession", id: "s", fresh: false } }),
      task("soon", { nextRun: "2026-11-17T13:00:00" }),
      task("paused", { enabled: false }),
    ];
    expect(nookTasks(tasks).map((t) => t.id)).toEqual(["soon", "later", "paused"]);
    expect(nookTasks(tasks, "ASK LATER").map((t) => t.id)).toEqual(["later"]);
    const { active, resting } = splitTasks(nookTasks(tasks));
    expect(active.map((t) => t.id)).toEqual(["soon", "later"]);
    expect(resting.map((t) => t.id)).toEqual(["paused"]);
  });

  it("says in one line what a task is doing and shows autonomous levels", () => {
    expect(taskStatus(task("a", { running: true }), now)).toBe("Running…");
    expect(taskStatus(task("a", { enabled: false }), now)).toBe("Paused");
    const once = task("a", { rule: { type: "once", at: "2026-11-17T08:00:00Z" }, lastRun: "2026-11-17T08:00:00Z", lastStatus: "succeeded" });
    expect(isDone(once)).toBe(true);
    expect(taskStatus(once, now)).toBe("Done");
    expect(taskDetail(task("a", { nextRun: "2026-11-17T13:00:00" }), now)).toMatch(/^Every day at 09:00 · next \d/);
    expect(taskDetail(task("a", { autonomy: "decide", nextRun: "2026-11-17T13:00:00" }), now)).toMatch(/^Every day at 09:00 · Nook decides · next \d/);
    expect(taskDetail(task("a", { autonomy: "auto", enabled: false }), now)).toBe("Every day at 09:00 · Do it · Paused");
  });

  it("lets Nook's non-webhook tasks run without the global agent switch", () => {
    expect(mayRunTask(task("a"), false)).toBe(true);
    expect(mayRunTask(task("a", { rule: { type: "webhook" } }), false)).toBe(false);
    expect(mayRunTask(task("a", { rule: { type: "webhook" } }), true)).toBe(true);
    expect(mayRunTask(task("a", { target: { type: "existingSession", id: "s", fresh: false } }), false)).toBe(false);
  });

  it("opens the latest run and counts the runs that wait for you", () => {
    const nooks = [run("r1", "a", "idle", "2026-11-16T09:00:00Z"), run("r2", "a", "waiting", "2026-11-17T09:00:00Z"), run("r3", "b", "unread", "2026-11-17T09:00:00Z")];
    expect(latestRun("a", nooks)?.id).toBe("r2");
    expect(latestRun("c", nooks)).toBeUndefined();
    expect(tabBadge([task("a"), task("b"), task("c")], nooks)).toEqual({ waiting: 1, fresh: true });
    expect(tabBadge([task("a")], [run("r1", "a", "idle", "2026-11-16T09:00:00Z")])).toEqual({ waiting: 0, fresh: false });
  });
});
