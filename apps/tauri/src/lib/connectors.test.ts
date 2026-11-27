import { describe, expect, it } from "vitest";
import {
  classifyCodeHost,
  codeHostTokenPage,
  forgeDetail,
  forgeHealth,
  gitlabDetail,
  gitlabHealth,
  health,
  inCategory,
  matchesQuery,
  normalizeCodeHost,
  type ConnectorInfo,
} from "./connectors";

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

  it("ignores accents and case, and wants every word (ConnectorGallerySearch)", () => {
    expect(matchesQuery("cafe", "Café Agenda")).toBe(true);
    expect(matchesQuery("CAFÉ", "cafe agenda")).toBe(true);
    expect(matchesQuery("agenda work", "Work calendar · agenda")).toBe(true);
    expect(matchesQuery("agenda mail", "Work calendar · agenda")).toBe(false);
    expect(matchesQuery("merge-requests", "GitLab merge requests")).toBe(true);
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

describe("code host helpers (AG-124)", () => {
  it("classifies hosts and normalizes URLs", () => {
    expect(classifyCodeHost("gitlab.com")).toBe("gitlab");
    expect(classifyCodeHost("codeberg.org")).toBe("gitea");
    expect(classifyCodeHost("git.example.com:8443")).toBe("gitea");
    expect(classifyCodeHost("git.cafe")).toBe("gitcafe");
    expect(classifyCodeHost("bitbucket.org")).toBe("bitbucket");
    expect(classifyCodeHost("dev.azure.com")).toBe("azureDevOps");

    expect(normalizeCodeHost("https://Codeberg.org/org/repo")).toBe("codeberg.org");
    expect(normalizeCodeHost("user@codeberg.org")).toBeNull();
    expect(normalizeCodeHost("intranet")).toBeNull();

    expect(codeHostTokenPage("gitea", "codeberg.org")).toBe("https://codeberg.org/user/settings/applications");
    expect(codeHostTokenPage("bitbucket", "bitbucket.org")).toBe("https://id.atlassian.com/manage-profile/security/api-tokens");
    expect(codeHostTokenPage("azureDevOps", "dev.azure.com")).toBe("https://dev.azure.com/_usersSettings/tokens");
  });

  it("reports forge health and detail", () => {
    expect(forgeHealth("azureDevOps", null)).toBe("working");
    expect(forgeHealth("gitea", null)).toBe("busy");
    expect(forgeHealth("gitea", { kind: "valid", account: "michan" })).toBe("working");
    expect(forgeHealth("bitbucket", { kind: "rejected" })).toBe("needsYou");
    expect(forgeDetail("codeberg.org", "gitea", { kind: "valid", account: "michan" })).toBe("codeberg.org · @michan");
    expect(forgeDetail("dev.azure.com", "azureDevOps", null)).toContain("dev.azure.com");
  });
});
