import { describe, expect, it } from "vitest";
import type { RunEvent } from "./api";
import { filterTimeline, timelineDetail } from "./timeline-detail";

const ev = (id: string, kind: RunEvent["kind"], state?: RunEvent["state"]): RunEvent => ({ id, date: "", kind, text: id, state });

const events: RunEvent[] = [
  ev("u1", "user"),
  ev("think", "thinking"),
  ev("a1", "assistant"),
  ev("readOk", "tool", "done"),
  ev("editOk", "fileChange"),
  ev("bgRun", "tool", "running"),
  ev("failed", "tool", "failed"),
  ev("approval", "approval", "pending"),
  ev("a2", "assistant"),
  ev("err", "error"),
  ev("sys", "system"),
  ev("u2", "user"),
  ev("a3", "assistant"),
  ev("a4", "assistant"),
];
const ids = (list: RunEvent[]) => list.map((e) => e.id);

describe("timeline detail", () => {
  it("everything keeps every event", () => {
    expect(filterTimeline(events, "everything")).toBe(events);
  });

  it("hide finished steps keeps running, pending and failed steps", () => {
    expect(ids(filterTimeline(events, "hideSucceeded"))).toEqual(["u1", "think", "a1", "bgRun", "failed", "approval", "a2", "err", "sys", "u2", "a3", "a4"]);
  });

  it("hide all steps drops every tool and edit but keeps thinking, approvals and errors", () => {
    expect(ids(filterTimeline(events, "noTools"))).toEqual(["u1", "think", "a1", "approval", "a2", "err", "sys", "u2", "a3", "a4"]);
  });

  it("zen keeps only the last answer of each turn, your messages and what waits or failed", () => {
    expect(ids(filterTimeline(events, "zen"))).toEqual(["u1", "approval", "a2", "err", "sys", "u2", "a4"]);
  });

  it("an unknown stored value shows everything", () => {
    expect(timelineDetail("zen")).toBe("zen");
    expect(timelineDetail("loud")).toBe("everything");
    expect(timelineDetail(undefined)).toBe("everything");
  });
});
