import { describe, expect, it } from "vitest";
import { needsSignIn, versionRejected } from "./agent-updates";

describe("failures an update or sign-in fixes", () => {
  it("reads a version refusal", () => {
    expect(versionRejected("API Error: 400 Claude Code 2.1.100 does not support this model; version 2.1.200 or newer is required.")).toBe(true);
    expect(versionRejected("The 'gpt-5.5' model requires a newer version of Codex.")).toBe(true);
    expect(versionRejected("network error")).toBe(false);
  });
  it("reads an expired login", () => {
    expect(needsSignIn("OAuth session expired and could not be refreshed")).toBe(true);
    expect(needsSignIn("fetch failed")).toBe(false);
  });
});
