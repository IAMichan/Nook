// Pure layout and presentation rules for the shared Settings building blocks (UI-11), mirroring the Mac's
// `SettingsTile` (`SettingsStyle.swift`), `SettingsLinkRow` & `InUseLabel` (`SettingsBlocks.swift`), and
// `ConnectMethodBadge` (`ServiceRows.swift`).
import { methodLabel, type ConnectMethod } from "./connectors";

export type TileRadiusToken = "chip" | "control" | "card" | "panel";

export interface TileMetrics {
  size: number;
  iconSize: number;
  radiusToken: TileRadiusToken;
}

/**
 * Tile geometry matching the Mac's `SettingsTile` (glyph at `size * 0.48`, rounded corner `size * 0.27` mapped onto
 * the theme's continuous radius tokens so views never write inline px radii).
 */
export function tileMetrics(size = 22): TileMetrics {
  const safe = Number.isFinite(size) && size > 0 ? Math.round(size) : 22;
  const iconSize = Math.max(10, Math.round(safe * 0.48));
  const radiusToken: TileRadiusToken = safe <= 28 ? "chip" : safe <= 36 ? "control" : safe <= 44 ? "card" : "panel";
  return { size: safe, iconSize, radiusToken };
}

export type LinkRowState = "done" | "todo" | "warning" | "error";

export interface LinkRowStateMeta {
  /** A done state stays quiet; only what still needs attention draws a status glyph. */
  showIcon: boolean;
  icon: "circle" | "triangle-alert" | "circle-x" | null;
  iconSize: number;
  iconStroke: number;
  tone: "todo" | "warning" | "error" | null;
  detailTone: "secondary" | "warning" | "error";
}

/** State glyph and detail color for `SettingsLinkRow`, mirroring `SettingsBlocks.swift`. */
export function linkRowStateMeta(state?: LinkRowState | null): LinkRowStateMeta {
  switch (state) {
    case "todo":
      return { showIcon: true, icon: "circle", iconSize: 18, iconStroke: 1.5, tone: "todo", detailTone: "secondary" };
    case "warning":
      return { showIcon: true, icon: "triangle-alert", iconSize: 17, iconStroke: 1.6, tone: "warning", detailTone: "warning" };
    case "error":
      return { showIcon: true, icon: "circle-x", iconSize: 18, iconStroke: 1.5, tone: "error", detailTone: "error" };
    default:
      return { showIcon: false, icon: null, iconSize: 18, iconStroke: 1.5, tone: null, detailTone: "secondary" };
  }
}

export interface ConnectMethodBadgeSpec {
  label: string;
  /** Sign-in is the easiest path, so its badge is filled in `--iris`; key and MCP stay tinted. */
  filled: boolean;
}

/** Label and visual emphasis for `ConnectMethodBadge`, mirroring `ServiceRows.swift`. */
export function connectMethodBadgeSpec(method: ConnectMethod, text?: string | null): ConnectMethodBadgeSpec {
  const override = text?.trim();
  return {
    label: override ? override : methodLabel[method],
    filled: method === "signIn",
  };
}
