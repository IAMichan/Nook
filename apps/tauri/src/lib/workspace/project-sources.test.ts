import { describe, expect, it } from "vitest";
import {
  githubCloneUrl,
  isValidCloneUrl,
  multiProjectLabel,
  multiProjectNames,
  repositoryUrlFromPage,
  sanitizeProjectName,
} from "./project-sources";

describe("project-sources helpers (AG-113)", () => {
  it("parses GitHub shorthand, domain, and page URLs", () => {
    expect(githubCloneUrl("IAMichan/Nook")).toBe("https://github.com/IAMichan/Nook.git");
    expect(githubCloneUrl("github.com/acme/app.git")).toBe("https://github.com/acme/app.git");
    expect(githubCloneUrl("https://github.com/acme/app/pull/42")).toBe("https://github.com/acme/app.git");
    expect(githubCloneUrl("git@github.com:acme/app.git")).toBe("git@github.com:acme/app.git");
    expect(githubCloneUrl("https://gitlab.com/acme/app")).toBeNull();
    expect(githubCloneUrl("https://evil.example/github.com/acme/app")).toBeNull();
    expect(githubCloneUrl("single-word")).toBeNull();
    expect(githubCloneUrl("acme/..")).toBeNull();
  });

  it("normalizes and validates clone URLs", () => {
    expect(repositoryUrlFromPage("https://gitlab.com/org/sub/repo/-/merge_requests/9")).toBe(
      "https://gitlab.com/org/sub/repo.git",
    );
    expect(isValidCloneUrl("https://github.com/acme/app.git")).toBe(true);
    expect(isValidCloneUrl("git@github.com:acme/app.git")).toBe(true);
    expect(isValidCloneUrl("not a url")).toBe(false);
    expect(isValidCloneUrl("https://github.com/only-owner")).toBe(false);
  });

  it("sanitizes new project folder names", () => {
    expect(sanitizeProjectName("  my/new:app  ")).toBe("my-new-app");
    expect(sanitizeProjectName("..")).toBe("");
    expect(sanitizeProjectName("demo\\repo")).toBe("demo-repo");
  });

  it("formats multi-project session labels (#1549)", () => {
    expect(multiProjectLabel("Nook", [])).toBe("Nook");
    expect(multiProjectLabel("Nook", ["/work/monorepo"])).toBe("Nook + monorepo");
    expect(multiProjectLabel("Nook", ["/work/Nook", "/work/monorepo", "/other/monorepo", "/work/docs", "/work/site"])).toBe(
      "Nook + monorepo +2",
    );
    expect(multiProjectNames(["C:\\dev\\api", "C:\\dev\\web"], "Nook")).toEqual(["api", "web"]);
  });
});
