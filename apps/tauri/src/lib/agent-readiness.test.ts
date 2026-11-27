import { describe, expect, it } from "vitest";
import { agentState, anyReady, classify, readinessAction } from "./agent-readiness";
import type { AgentProfile, HistoryResult } from "./agents";

const history = (over: Partial<HistoryResult> = {}): HistoryResult => ({ sessions: [], accounts: {}, usage: {}, installed: [], executables: {}, ...over });
const profile = (id: string, kind: AgentProfile["kind"]): AgentProfile => ({
  id, kind, label: id, home: null, auth: null, title: id, displayHome: "", preferred: true, hasKey: false, launchCommand: "", loginCommand: "", enabled: true,
});

describe("agent-readiness (AgentReadiness)", () => {
  it("classifies an agent", () => {
    expect(classify(false, false, false, false)).toBe("checking");
    expect(classify(true, false, true, false)).toBe("missing");
    expect(classify(true, true, false, false)).toBe("signIn");
    expect(classify(true, true, true, false)).toBe("ready");
    expect(classify(true, true, true, true)).toBe("connecting");
  });

  it("offers install or sign in only where it helps", () => {
    expect(readinessAction("missing")).toBe("install");
    expect(readinessAction("signIn")).toBe("signIn");
    expect(readinessAction("ready")).toBe("none");
    expect(readinessAction("connecting")).toBe("none");
    expect(anyReady(["missing", "ready"])).toBe(true);
    expect(anyReady(["signIn"])).toBe(false);
  });

  it("reads the scan and the accounts", () => {
    const profiles = [profile("claude-default", "claude")];
    expect(agentState("claude", null, profiles, false)).toBe("checking");
    expect(agentState("claude", history(), profiles, false)).toBe("missing");
    expect(agentState("claude", history({ installed: ["claude"] }), profiles, false)).toBe("signIn");
    expect(agentState("claude", history({ executables: { claude: "C:\\bin\\claude.exe" }, accounts: { "claude-default": { agent: "claude", name: "me", organization: "", plan: "pro" } } }), profiles, false)).toBe("ready");
  });
});
