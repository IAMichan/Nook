import { describe, expect, it } from "vitest";
import { CALLING_APPS, GROUP_CALLING_APPS, callAppUrl, callClock, callElapsed, canCallChat, type ActiveCallSnapshot } from "./chats-call";

describe("chats-call", () => {
  it("matches calling and group-calling app rules", () => {
    for (const app of CALLING_APPS) {
      expect(canCallChat(app, false)).toBe(true);
      expect(callAppUrl(app)).not.toBeNull();
    }
    for (const app of GROUP_CALLING_APPS) {
      expect(CALLING_APPS.has(app)).toBe(true);
      expect(canCallChat(app, true)).toBe(true);
    }
    expect(canCallChat("instagram", true)).toBe(false);
    expect(canCallChat("linkedin", false)).toBe(false);
    expect(canCallChat("mail", false)).toBe(false);
    expect(canCallChat("messages", false)).toBe(false);
  });

  it("formats call duration like a phone", () => {
    expect(callClock(-5)).toBe("0:00");
    expect(callClock(0)).toBe("0:00");
    expect(callClock(7)).toBe("0:07");
    expect(callClock(247)).toBe("4:07");
    expect(callClock(3753)).toBe("1:02:33");
  });

  it("computes elapsed seconds for calling, live, and ended phases", () => {
    const base: ActiveCallSnapshot = {
      id: "1",
      chatKey: "whatsapp#1",
      chatId: "1",
      app: "whatsapp",
      appName: "WhatsApp",
      name: "Anna",
      kind: "voice",
      direct: false,
      started: "2026-01-01T10:00:00.000Z",
      phase: { phase: "calling" },
      devices: { microphone: null, speaker: null, camera: null },
    };
    const t0 = Date.parse("2026-01-01T10:00:00.000Z");
    expect(callElapsed(base, t0 + 15_000)).toBe(15);
    expect(callElapsed({ ...base, phase: { phase: "live", since: "2026-01-01T10:00:10.000Z" } }, t0 + 75_000)).toBe(65);
    expect(callElapsed({ ...base, phase: { phase: "ended", seconds: 42, at: "2026-01-01T10:01:00.000Z" } }, t0 + 120_000)).toBe(42);
  });
});
