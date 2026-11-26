import { describe, expect, it } from "vitest";
import { connectMethodBadgeSpec, linkRowStateMeta, tileMetrics } from "./settings-ui";

describe("Settings UI helpers (UI-11)", () => {
  it("scales SettingsTile icon size and theme radius tokens like the Mac", () => {
    expect(tileMetrics()).toEqual({ size: 22, iconSize: 11, radiusToken: "chip" });
    expect(tileMetrics(26)).toEqual({ size: 26, iconSize: 12, radiusToken: "chip" });
    expect(tileMetrics(32)).toEqual({ size: 32, iconSize: 15, radiusToken: "control" });
    expect(tileMetrics(40)).toEqual({ size: 40, iconSize: 19, radiusToken: "card" });
    expect(tileMetrics(48)).toEqual({ size: 48, iconSize: 23, radiusToken: "panel" });
    expect(tileMetrics(0)).toEqual({ size: 22, iconSize: 11, radiusToken: "chip" });
    expect(tileMetrics(Number.NaN)).toEqual({ size: 22, iconSize: 11, radiusToken: "chip" });
  });

  it("keeps done SettingsLinkRow states quiet and highlights warning/error states", () => {
    expect(linkRowStateMeta(null)).toMatchObject({ showIcon: false, icon: null, tone: null, detailTone: "secondary" });
    expect(linkRowStateMeta("done")).toMatchObject({ showIcon: false, icon: null, tone: null, detailTone: "secondary" });
    expect(linkRowStateMeta("todo")).toMatchObject({ showIcon: true, icon: "circle", tone: "todo", detailTone: "secondary" });
    expect(linkRowStateMeta("warning")).toMatchObject({ showIcon: true, icon: "triangle-alert", tone: "warning", detailTone: "warning" });
    expect(linkRowStateMeta("error")).toMatchObject({ showIcon: true, icon: "circle-x", tone: "error", detailTone: "error" });
  });

  it("renders ConnectMethodBadge filled only for sign-in and respects override labels", () => {
    expect(connectMethodBadgeSpec("signIn")).toEqual({ label: "Sign in", filled: true });
    expect(connectMethodBadgeSpec("key")).toEqual({ label: "With key", filled: false });
    expect(connectMethodBadgeSpec("mcp")).toEqual({ label: "MCP", filled: false });
    expect(connectMethodBadgeSpec("signIn", "Retry")).toEqual({ label: "Retry", filled: true });
    expect(connectMethodBadgeSpec("key", "   ")).toEqual({ label: "With key", filled: false });
  });
});
