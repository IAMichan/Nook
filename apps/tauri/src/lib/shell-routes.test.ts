import { afterEach, describe, expect, it, vi } from "vitest";
import type { Component } from "svelte";
import { matchesSearch, parseRoute, reloadRoute, resumeRoute, retryableView, settingsSection, type ViewModule } from "./shell-routes";

afterEach(() => vi.unstubAllGlobals());

describe("shell route loading", () => {
  it("falls back to chat for unknown external routes", () => {
    for (const route of [null, "", "__proto__", "constructor", "missing"]) expect(parseRoute(route)).toBe("chat");
    for (const route of ["chat", "agents", "chats", "music", "workspace", "games", "settings", "companion"]) expect(parseRoute(route)).toBe(route);
  });

  it("shares a pending import and reuses a successful download", async () => {
    const view: ViewModule = { default: vi.fn<Component>() };
    const download = vi.fn(async () => view);
    const load = retryableView(download);
    const first = load();
    expect(load()).toBe(first);
    expect(await first).toBe(view);
    expect(await load()).toBe(view);
    expect(download).toHaveBeenCalledTimes(1);
  });

  it("retries a rejected import rather than caching the error", async () => {
    const view: ViewModule = { default: vi.fn<Component>() };
    const download = vi.fn<() => Promise<ViewModule>>()
      .mockRejectedValueOnce(new Error("Offline"))
      .mockResolvedValue(view);
    const load = retryableView(download);
    await expect(load()).rejects.toThrow("Offline");
    expect(await load()).toBe(view);
    expect(download).toHaveBeenCalledTimes(2);
  });

  it("restores the failed route once after an explicit reload", () => {
    const values = new Map<string, string>();
    const reload = vi.fn();
    vi.stubGlobal("sessionStorage", {
      getItem: (key: string) => values.get(key) ?? null,
      setItem: (key: string, value: string) => values.set(key, value),
      removeItem: (key: string) => values.delete(key),
    });
    vi.stubGlobal("window", { location: { reload } });
    reloadRoute("settings");
    expect(reload).toHaveBeenCalledTimes(1);
    expect(resumeRoute()).toBe("settings");
    expect(resumeRoute()).toBe("chat");
  });

  it("still reloads and falls back to chat when storage is unavailable", () => {
    const reload = vi.fn();
    vi.stubGlobal("sessionStorage", {
      getItem: () => { throw new Error("Blocked"); },
      setItem: () => { throw new Error("Blocked"); },
    });
    vi.stubGlobal("window", { location: { reload } });
    reloadRoute("agents");
    expect(reload).toHaveBeenCalledTimes(1);
    expect(resumeRoute()).toBe("chat");
  });
});

describe("settings pages", () => {
  it("opens a known page, an alias, or Overview", () => {
    expect(settingsSection("brain")).toBe("brain");
    expect(settingsSection("connections")).toBe("accounts");
    expect(settingsSection("start")).toBe("overview");
    for (const value of [null, undefined, "", "__proto__", "constructor", "missing"]) expect(settingsSection(value)).toBe("overview");
  });

  it("finds a page by any word of its name or group, ignoring case and accents", () => {
    expect(matchesSearch("", "Brain")).toBe(true);
    expect(matchesSearch("geluid", "Stem en Geluid")).toBe(true);
    expect(matchesSearch("reglages gen", "Réglages généraux")).toBe(true);
    expect(matchesSearch("coding", "Coding agents", "Agents")).toBe(true);
    expect(matchesSearch("memory", "Brain", "Intelligence")).toBe(false);
  });
});
