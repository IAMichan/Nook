import { beforeEach, describe, expect, it } from "vitest";
import { deployErrorText, deployStepText, normalizeRelayUrl, ownRelayCheckState } from "./cloudflare-relay";
import { nook } from "./state.svelte";

describe("cloudflare-relay helpers", () => {
  beforeEach(() => {
    nook.settings = { ...(nook.settings ?? {}), appLanguage: "en" } as typeof nook.settings;
  });

  it("normalizes https relay URLs and rejects http or invalid URLs", () => {
    expect(normalizeRelayUrl("https://nook-relay.me.workers.dev/")).toBe("https://nook-relay.me.workers.dev");
    expect(normalizeRelayUrl("  https://relay.example.com  ")).toBe("https://relay.example.com");
    expect(normalizeRelayUrl("http://nook-relay.me.workers.dev")).toBeNull();
    expect(normalizeRelayUrl("not a url")).toBeNull();
    expect(normalizeRelayUrl("")).toBeNull();
  });

  it("formats each deploy step and structured error", () => {
    expect(deployStepText("account")).toBe("Finding your Cloudflare account…");
    expect(deployStepText("uploading")).toBe("Putting the relay on your account…");
    expect(deployStepText("starting")).toBe("Starting the relay…");

    expect(deployErrorText({ kind: "badToken" })).toContain("Open Cloudflare");
    expect(deployErrorText({ kind: "noAccount" })).toContain("Cloudflare account");
    expect(deployErrorText({ kind: "severalAccounts" })).toContain("several Cloudflare accounts");
    expect(deployErrorText({ kind: "noSubdomain" })).toContain("workers.dev");
    expect(deployErrorText({ kind: "noAnswer" })).toContain("minute");
    expect(deployErrorText({ kind: "cloudflare", detail: "Cloudflare: HTTP 500" })).toBe("Cloudflare: HTTP 500");
  });

  it("derives SetupCheckState through working, failure, connecting, and connected", () => {
    expect(ownRelayCheckState(false, { state: "idle" }, "", { state: "off" })).toEqual({ kind: "idle" });
    expect(ownRelayCheckState(true, { state: "working", step: "uploading" }, "", { state: "off" })).toEqual({
      kind: "checking",
    });
    expect(
      ownRelayCheckState(true, { state: "failed", error: { kind: "badToken" } }, "", { state: "off" }),
    ).toEqual({
      kind: "failed",
      message:
        "Setting up did not work: Cloudflare did not accept this token. Copy it again, or create a new one with Open Cloudflare.",
    });
    expect(
      ownRelayCheckState(true, { state: "idle" }, "https://nook-relay.me.workers.dev", { state: "connecting" }),
    ).toEqual({ kind: "checking" });
    expect(
      ownRelayCheckState(true, { state: "idle" }, "https://nook-relay.me.workers.dev", { state: "connected" }),
    ).toEqual({
      kind: "passed",
      message: "Connected to the relay. Your phone now finds this computer on the go too.",
    });
    expect(
      ownRelayCheckState(true, { state: "idle" }, "https://nook-relay.me.workers.dev", {
        state: "failed",
        message: "timeout",
      }),
    ).toEqual({
      kind: "failed",
      message: "The relay can't be reached: timeout",
    });
  });
});
