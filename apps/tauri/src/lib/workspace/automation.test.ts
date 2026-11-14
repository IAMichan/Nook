import { describe, expect, it } from "vitest";
import { blankTask, curlExample, editorValues, presetOf, problem, reasonLabel, ruleFor, ruleLabel } from "./automation";

const values = { minutes: 30, time: "07:05", weekdays: [] as number[], at: "2099-01-02T03:04" };

describe("scheduled task editor", () => {
  it("turns presets into rules and back", () => {
    expect(ruleFor("interval", values)).toEqual({ type: "interval", seconds: 1800 });
    expect(ruleFor("interval", { ...values, minutes: 0 })).toEqual({ type: "interval", seconds: 60 });
    expect(ruleFor("daily", values)).toEqual({ type: "fixedTime", hour: 7, minute: 5, weekdays: [] });
    expect(ruleFor("weekdays", values)).toEqual({ type: "fixedTime", hour: 7, minute: 5, weekdays: [2, 3, 4, 5, 6] });
    expect(ruleFor("weekdays", { ...values, weekdays: [6, 2] })).toEqual({ type: "fixedTime", hour: 7, minute: 5, weekdays: [2, 6] });
    expect(ruleFor("webhook", values)).toEqual({ type: "webhook" });
    const once = ruleFor("once", values);
    expect(once.type).toBe("once");
    expect(editorValues(once).at).toBe("2099-01-02T03:04");
    expect(presetOf({ type: "fixedTime", hour: 1, minute: 2, weekdays: [1] })).toBe("weekdays");
    expect(presetOf({ type: "fixedTime", hour: 1, minute: 2, weekdays: [] })).toBe("daily");
    expect(editorValues({ type: "fixedTime", hour: 7, minute: 5, weekdays: [3] })).toMatchObject({ time: "07:05", weekdays: [3] });
    expect(editorValues({ type: "interval", seconds: 5400 }).minutes).toBe(90);
  });

  it("says what is missing", () => {
    const t = blankTask("", "claude");
    expect(problem(t)).toBeTruthy();
    t.prompt = "Check the build";
    expect(problem(t)).toBeTruthy();
    t.target = { type: "newSession", projectPath: "/p", provider: "claude", profileId: null };
    expect(problem(t)).toBeNull();
    t.rule = { type: "once", at: "2000-01-01T00:00:00Z" };
    expect(problem(t)).toBeTruthy();
    expect(t.permission).toBe("ask");
    expect(t.enabled).toBe(true);
  });

  it("labels rules and reasons", () => {
    expect(ruleLabel({ type: "webhook" })).toBeTruthy();
    expect(ruleLabel({ type: "fixedTime", hour: 9, minute: 0, weekdays: [] })).toContain("09:00");
    expect(reasonLabel("sched.skip.missed")).not.toBe("sched.skip.missed");
    expect(reasonLabel("boom")).toBe("boom");
    expect(reasonLabel(null)).toBeNull();
    expect(curlExample("http://127.0.0.1:8787/hooks/x")).toContain("X-Hub-Signature-256: sha256=$sig");
  });
});
