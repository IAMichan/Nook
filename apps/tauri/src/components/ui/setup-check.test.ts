import { describe, expect, it } from "vitest";
import { isSetupCheckPassed, setupCheck, setupCheckFromHealth } from "./setup-check";

describe("setup-check helpers", () => {
  it("constructs every SetupCheckState variant and reports passed accurately", () => {
    const idle = setupCheck.idle();
    const checking = setupCheck.checking();
    const passed = setupCheck.passed("Connected as @octocat");
    const failed = setupCheck.failed("Invalid token");

    expect(isSetupCheckPassed(idle)).toBe(false);
    expect(isSetupCheckPassed(checking)).toBe(false);
    expect(isSetupCheckPassed(passed)).toBe(true);
    expect(isSetupCheckPassed(failed)).toBe(false);
    expect(passed).toEqual({ kind: "passed", message: "Connected as @octocat" });
    expect(failed).toEqual({ kind: "failed", message: "Invalid token" });
  });

  it("maps connector Health values to SetupCheckState", () => {
    const messages = { passed: "Done!", failed: "Could not connect." };
    expect(setupCheckFromHealth("notLinked", messages)).toEqual({ kind: "idle" });
    expect(setupCheckFromHealth("off", messages)).toEqual({ kind: "idle" });
    expect(setupCheckFromHealth("busy", messages)).toEqual({ kind: "checking" });
    expect(setupCheckFromHealth("working", messages)).toEqual({ kind: "passed", message: "Done!" });
    expect(setupCheckFromHealth("needsYou", messages)).toEqual({ kind: "passed", message: "Done!" });
    expect(setupCheckFromHealth("broken", messages)).toEqual({ kind: "failed", message: "Could not connect." });
  });
});
