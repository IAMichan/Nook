import { describe, expect, it } from "vitest";
import { clock, coachingText, habitText, listRounds, newCoaching, statusLabel, type Insight } from "./games";

const setup = { agentName: "Cypher", abilityName: "Trapwire", kind: "trap" as const, location: "B Main" };

describe("valorant coaching text", () => {
  it("formats round time and rounds the way the game does", () => {
    expect(clock(6)).toBe("0:06");
    expect(clock(75)).toBe("1:15");
    expect(listRounds([1, 2, 3], "en")).toBe("1, 2 and 3");
    expect(listRounds([4], "nl")).toBe("4");
  });

  it("warns about a reused trip and counts the triggers", () => {
    const strong: Insight = { id: "a", round: 3, severity: "warning", type: "patternStrong", ...setup, occurrences: 3, streak: 3, hits: 3, typicalTime: null };
    const text = coachingText(strong, "en");
    expect(text.title).toBe("Cypher pattern detected");
    expect(text.body).toContain("You've triggered it 3 times.");
    expect(text.body).toContain("Check this location before entering B Main.");
  });

  it("says the enemy adapted rather than repeating the old setup", () => {
    const changed: Insight = { id: "b", round: 6, severity: "warning", type: "patternChanged", ...setup, occurrences: 5, movedTo: null };
    const text = coachingText(changed, "en");
    expect(text.body).toContain("wasn't detected in round 6");
    expect(text.body).toContain("Be careful relying on the old setup.");
  });

  it("praises a dodge and words flashes with their timing", () => {
    const flash = { agentName: "Skye", abilityName: "Guiding Light", kind: "flash" as const, location: "A Main" };
    const good: Insight = { id: "c", round: 4, severity: "success", type: "goodAdaptation", ...flash, occurrences: 4 };
    expect(coachingText(good, "en").body).toBe("You avoided Skye's usual Guiding Light at A Main. It has now been used 4 times.");
    const strong: Insight = { id: "d", round: 3, severity: "warning", type: "patternStrong", ...flash, occurrences: 3, streak: 3, hits: 0, typicalTime: 6 };
    expect(coachingText(strong, "en").body).toContain("You've seen it 3 rounds in a row. Expect it early in the round, around 0:06.");
  });

  it("names habits in both languages", () => {
    const habit = { type: "repeatTrigger" as const, key: "k", ...setup, count: 3, rounds: [1, 2, 3] };
    expect(habitText(habit, "en").body).toContain("triggered the same Cypher Trapwire at B Main 3 times");
    expect(habitText(habit, "nl").body).toContain("3 keer");
    expect(statusLabel({ state: "stale", since: 4 }, 3, "en")).toBe("Not seen since round 4");
  });

  it("only notifies warnings and good news it has not shown yet", () => {
    const list: Insight[] = [
      { id: "old", round: 1, severity: "warning", type: "habit", habit: { type: "repeatDeath", location: "Mid", count: 2, rounds: [1, 2] } },
      { id: "maybe", round: 2, severity: "info", type: "patternForming", ...setup, occurrences: 2, rounds: [1, 2] },
      { id: "new", round: 2, severity: "success", type: "goodAdaptation", ...setup, occurrences: 2 },
    ];
    expect(newCoaching(new Set(["old"]), list).map((i) => i.id)).toEqual(["new"]);
  });
});
