import { describe, expect, it } from "vitest";
import { checklistProgress } from "./task-steps";

describe("checklistProgress", () => {
  it("counts done steps and leaves dropped ones out", () => {
    expect(
      checklistProgress([
        { text: "a", status: "done" },
        { text: "b", status: "active" },
        { text: "c", status: "cancelled" },
        { text: "d", status: "pending" },
      ]),
    ).toEqual({ done: 1, total: 3 });
    expect(checklistProgress([])).toEqual({ done: 0, total: 0 });
  });
});
