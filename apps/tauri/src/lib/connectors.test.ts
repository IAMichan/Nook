import { describe, expect, it } from "vitest";
import { gitlabDetail, gitlabHealth, health, inCategory, matchesQuery, type ConnectorInfo } from "./connectors";

function info(partial: Partial<ConnectorInfo["status"]>): ConnectorInfo {
  return {
    id: "github",
    title: "GitHub",
    configured: true,
    on: true,
    status: { state: { kind: "ok" }, headline: "", detail: "", items: [], updated: null, needsAttention: false, errorKind: null, ...partial },
  };
}

describe("health", () => {
  it("treats items waiting for you as content, not as a broken link", () => {
    expect(health(info({ needsAttention: true }))).toBe("working");
    expect(health(info({ state: { kind: "error", message: "401" }, errorKind: "auth" }))).toBe("needsYou");
    expect(health(info({ state: { kind: "error", message: "offline" }, errorKind: "network" }))).toBe("broken");
  });
});

describe("catalogue filters", () => {
  it("filters by category chip and search", () => {
    expect(inCategory(null, "development")).toBe(true);
    expect(inCategory("work", "development")).toBe(false);
    expect(matchesQuery("  GIT ", "GitLab merge requests")).toBe(true);
    expect(matchesQuery("", "anything")).toBe(true);
    expect(matchesQuery("stripe", "GitLab")).toBe(false);
  });
});

describe("GitLab status", () => {
  it("says who is connected, or why not", () => {
    expect(gitlabHealth(null)).toBe("busy");
    expect(gitlabHealth({ kind: "valid", username: "michan" })).toBe("working");
    expect(gitlabHealth({ kind: "rejected" })).toBe("needsYou");
    expect(gitlabHealth({ kind: "unreachable" })).toBe("broken");
    expect(gitlabDetail("gitlab.com", { kind: "valid", username: "michan" })).toBe("gitlab.com · @michan");
    expect(gitlabDetail("git.example.com", { kind: "unreachable" })).toContain("git.example.com");
  });
});
