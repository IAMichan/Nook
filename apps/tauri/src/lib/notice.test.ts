import { describe, expect, it } from "vitest";
import { compactNotice, Countdown, noticeTone } from "./notice";

describe("agent notices", () => {
  it("count down only while the pointer is off the bar", () => {
    const clock = new Countdown(5, 100);
    clock.advance(2, false);
    expect(clock.fraction).toBeCloseTo(0.6);
    clock.advance(10, true);
    expect(clock.fraction).toBeCloseTo(0.6);
    expect(clock.done).toBe(false);
    clock.advance(3, false);
    expect(clock.done).toBe(true);
    expect(clock.fraction).toBe(0);
  });

  it("never stay longer than the maximum, even when hovered", () => {
    const clock = new Countdown(5, 20);
    clock.advance(19, true);
    expect(clock.done).toBe(false);
    clock.advance(1, true);
    expect(clock.done).toBe(true);
  });

  it("say in one line what the agent did", () => {
    expect(compactNotice("Claude Code", "nook", "done")).toBe("Claude Code is klaar · nook");
    expect(compactNotice("Codex", "", "failed")).toBe("Codex is gestopt met een fout");
    expect(compactNotice("Codex", "site", "waiting")).toBe("Codex wacht op je · site");
    expect(noticeTone("running")).toBe("waiting");
  });
});
