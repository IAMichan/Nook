import { describe, expect, it, vi, beforeEach } from "vitest";
import type { ChatEntry } from "./chats-list";

const invoked: Array<{ cmd: string; args?: Record<string, unknown> }> = [];
vi.mock("@tauri-apps/api/core", () => ({
  invoke: vi.fn((cmd: string, args?: Record<string, unknown>) => {
    invoked.push({ cmd, args });
    if (cmd === "chat_snoozes") return Promise.resolve({ "whatsapp#alice": Date.now() + 3_600_000 });
    return Promise.resolve(undefined);
  }),
}));

import {
  chatMenu,
  chatSnoozeMenu,
  chatSnoozedUntil,
  isChatSnoozed,
  snoozeChat,
  snoozes,
  unsnoozeChat,
} from "../views/chats/chat-actions.svelte";

function sampleEntry(key = "whatsapp#alice"): ChatEntry {
  return {
    id: "alice",
    key,
    app: "whatsapp",
    name: "Alice",
    isGroup: false,
    listKind: "chats",
    last: new Date("2026-11-26T12:00:00Z"),
    preview: "Are you free later?",
    ticks: null,
    unread: 1,
    read: "unread",
    lastIsMine: false,
    account: null,
    sends: true,
    mutedInApp: false,
  };
}

describe("chat snooze (CH-40)", () => {
  beforeEach(() => {
    invoked.length = 0;
    snoozes.untilByKey = {};
  });

  it("exposes configured snooze choices when a chat is not snoozed", () => {
    const entry = sampleEntry();
    const now = new Date(2026, 10, 26, 10, 0, 0);
    const items = chatSnoozeMenu(entry, now);
    expect(items[0].onselect).toBeUndefined();
    expect(items.length).toBeGreaterThan(1);
    expect(items.slice(1).every((item) => typeof item.onselect === "function")).toBe(true);
    expect(chatMenu(entry).flat().some((item) => item.icon === "alarm-clock")).toBe(true);
  });

  it("shows Bring it back now when snoozed and forwards chat_snooze commands", async () => {
    const entry = sampleEntry();
    const now = new Date(2026, 10, 26, 10, 0, 0);
    const until = new Date(now.getTime() + 60 * 60_000);

    await snoozeChat(entry, until);
    expect(invoked).toContainEqual({ cmd: "chat_snooze", args: { key: entry.key, until: until.getTime() } });
    expect(isChatSnoozed(entry, now.getTime())).toBe(true);
    expect(chatSnoozedUntil(entry, now.getTime())).toBe(until.getTime());

    const activeMenu = chatSnoozeMenu(entry, now);
    expect(activeMenu).toHaveLength(1);
    expect(activeMenu[0].icon).toBe("bell");
    expect(activeMenu[0].detail).toBeTruthy();

    await unsnoozeChat(entry);
    expect(invoked).toContainEqual({ cmd: "chat_snooze", args: { key: entry.key, until: null } });
    expect(isChatSnoozed(entry, now.getTime())).toBe(false);
  });

  it("treats past snooze timestamps as expired and refreshes from chat_snoozes", async () => {
    const entry = sampleEntry("telegram#bob");
    const now = Date.now();
    snoozes.set(entry.key, now - 10_000);
    expect(isChatSnoozed(entry, now)).toBe(false);

    await snoozes.refresh();
    expect(invoked.some((call) => call.cmd === "chat_snoozes")).toBe(true);
    expect(isChatSnoozed(sampleEntry("whatsapp#alice"), now)).toBe(true);
  });
});
