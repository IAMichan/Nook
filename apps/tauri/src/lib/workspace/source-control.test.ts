import { describe, expect, it } from "vitest";
import {
  commitHashInUrl,
  isCommitHash,
  isValidRepositoryName,
  suggestedRepositoryName,
} from "./source-control";

describe("source-control rules", () => {
  it("validates GitHub repository names", () => {
    expect(isValidRepositoryName("nook-app_1.0")).toBe(true);
    expect(isValidRepositoryName("")).toBe(false);
    expect(isValidRepositoryName(".")).toBe(false);
    expect(isValidRepositoryName("..")).toBe(false);
    expect(isValidRepositoryName("has space")).toBe(false);
    expect(isValidRepositoryName("a".repeat(101))).toBe(false);
  });

  it("suggests clean repository names from folder names", () => {
    expect(suggestedRepositoryName("My App (2)")).toBe("My-App-2");
    expect(suggestedRepositoryName("...")).toBe("project");
    expect(suggestedRepositoryName("nook_core")).toBe("nook_core");
  });

  it("recognizes commit hashes and commit URLs", () => {
    expect(isCommitHash("a1b2c3d")).toBe(true);
    expect(isCommitHash("deadbeef")).toBe(false);
    expect(isCommitHash("1234567")).toBe(false);
    expect(isCommitHash("A1B2C3D")).toBe(false);
    expect(commitHashInUrl("nook-commit:a1b2c3d")).toBe("a1b2c3d");
    expect(commitHashInUrl("https://github.com/acme/app/commit/a1b2c3d4")).toBe("a1b2c3d4");
    expect(commitHashInUrl("https://github.com/acme/app/pull/12/commits/f0e1d2c")).toBe("f0e1d2c");
    expect(commitHashInUrl("https://example.com/acme/app/commit/a1b2c3d")).toBeNull();
  });
});
