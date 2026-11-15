import { describe, expect, it } from "vitest";
import { agentFor, parsePromptLink, projectFor } from "./prompt-link";

describe("prompt links", () => {
  it("reads the task, folder, agent and model, and strips hidden characters", () => {
    expect(parsePromptLink("nook://prompt?text=Fix%20the%20tests%E2%80%8B&project=code/app&agent=Claude&model=opus-4")).toEqual({ text: "Fix the tests", project: "code/app", agent: "claude", model: "opus-4" });
    expect(parsePromptLink("nook://prompt?text=a&project=../etc")).toEqual({ text: "a" });
    expect(parsePromptLink("nook://prompt?text=")).toBeNull();
    expect(parsePromptLink("nook://prompt?text=" + "x".repeat(8001))).toBeNull();
    expect(parsePromptLink("https://prompt?text=a")).toBeNull();
  });
  it("finds the named folder and agent", () => {
    const projects = [{ name: "nook", path: "/u/code/nook" }, { name: "app", path: "/u/code/app" }];
    expect(projectFor("code/app", projects)?.name).toBe("app");
    expect(projectFor("NOOK", projects)?.name).toBe("nook");
    expect(agentFor("claude", [{ id: "codex" }, { id: "claude-code" }])?.id).toBe("claude-code");
  });
});
