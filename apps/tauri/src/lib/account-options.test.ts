import { describe, expect, it } from "vitest";
import {
  accountCustomModels,
  clashingHomeVariable,
  isValidVariableName,
  pickableProfiles,
  splitLines,
} from "./account-options";
import type { AgentProfile } from "./agents";

function makeProfile(overrides: Partial<AgentProfile> = {}): AgentProfile {
  return {
    id: "claude",
    kind: "claude",
    label: "",
    home: null,
    auth: null,
    title: "Claude Code",
    displayHome: "~/.claude",
    preferred: true,
    enabled: true,
    hasKey: false,
    homeVariable: "CLAUDE_CONFIG_DIR",
    launchCommand: "claude",
    loginCommand: "claude login",
    ...overrides,
  };
}

describe("account-options", () => {
  it("splits multiline arguments and models cleanly", () => {
    expect(splitLines("  --verbose \n\n --max-turns=5\r\n  ")).toEqual(["--verbose", "--max-turns=5"]);
    expect(splitLines("   \n  ")).toEqual([]);
  });

  it("validates shell variable names like AccountVariable.isValidName", () => {
    expect(isValidVariableName("HTTPS_PROXY")).toBe(true);
    expect(isValidVariableName("_x1")).toBe(true);
    expect(isValidVariableName("1X")).toBe(false);
    expect(isValidVariableName("A-B")).toBe(false);
    expect(isValidVariableName("")).toBe(false);
  });

  it("detects clashes only when an account has a custom home folder", () => {
    const primary = makeProfile({ home: null, homeVariable: "CLAUDE_CONFIG_DIR" });
    const work = makeProfile({ id: "claude-work", home: "/Users/me/.claude-work", homeVariable: "CLAUDE_CONFIG_DIR" });
    expect(clashingHomeVariable(primary, ["CLAUDE_CONFIG_DIR"])).toBeNull();
    expect(clashingHomeVariable(work, ["HTTPS_PROXY"])).toBeNull();
    expect(clashingHomeVariable(work, ["HTTPS_PROXY", " CLAUDE_CONFIG_DIR "])).toBe("CLAUDE_CONFIG_DIR");
  });

  it("omits disabled profiles from pickers unless currently active", () => {
    const a = makeProfile({ id: "claude", enabled: true });
    const b = makeProfile({ id: "claude-work", enabled: false });
    expect(pickableProfiles([a, b]).map((p) => p.id)).toEqual(["claude"]);
    expect(pickableProfiles([a, b], "claude-work").map((p) => p.id)).toEqual(["claude", "claude-work"]);
  });

  it("returns trimmed, unique custom models for an account", () => {
    expect(accountCustomModels(makeProfile({ customModels: [" gw-model ", "", "gw-model", "beta-1"] }))).toEqual([
      "gw-model",
      "beta-1",
    ]);
    expect(accountCustomModels(null)).toEqual([]);
  });
});
