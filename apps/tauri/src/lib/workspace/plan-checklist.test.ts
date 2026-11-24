import { describe, expect, it } from "vitest";
import { keptCount, keptText, planSteps } from "./plan-checklist";

const plan = "# Plan\n\n1. Read the code\n2. Change the login\n   - update the form\n   - update the API\n3. Write tests\n\n```\n- not a step\n```";

describe("plan checklist", () => {
  it("finds the steps outside code blocks", () => {
    expect(planSteps(plan).map((s) => s.text)).toEqual(["Read the code", "Change the login", "update the form", "update the API", "Write tests"]);
  });

  it("drops a left-out step with its sub-steps", () => {
    const steps = planSteps(plan);
    steps[1].kept = false;
    expect(keptCount(steps)).toBe(2);
    expect(keptText(plan, steps)).toBe("# Plan\n\n1. Read the code\n3. Write tests\n\n```\n- not a step\n```");
  });
});
