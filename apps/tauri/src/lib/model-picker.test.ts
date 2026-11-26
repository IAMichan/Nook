import { describe, expect, it } from "vitest";
import {
  clampedHighlight,
  groupPlaces,
  idAddsToName,
  modelSearchMatches,
  numberKeyRow,
  placeHelp,
  stepHighlight,
  type ModelPickerPlace,
} from "./model-picker";

describe("model-picker helpers", () => {
  it("groups local, symbolic, and agent places separately and omits empty groups", () => {
    const places: ModelPickerPlace[] = [
      { id: "claude", name: "Claude Code" },
      { id: "local", name: "On this computer", isLocal: true },
      { id: "auto", name: "Auto", symbol: "sparkles" },
      { id: "codex", name: "Codex" },
    ];
    expect(groupPlaces(places).map((g) => g.map((p) => p.id))).toEqual([
      ["local"],
      ["auto"],
      ["claude", "codex"],
    ]);
    expect(groupPlaces([{ id: "claude", name: "Claude Code" }]).map((g) => g.map((p) => p.id))).toEqual([["claude"]]);
  });

  it("formats place tooltips with detail for non-local places", () => {
    expect(placeHelp({ id: "local", name: "On this computer", detail: "Stays local", isLocal: true })).toBe("On this computer");
    expect(placeHelp({ id: "claude/work", name: "Claude Code", detail: "Work" })).toBe("Claude Code · Work");
    expect(placeHelp({ id: "claude", name: "Claude Code", help: "Custom tip" })).toBe("Custom tip");
  });

  it("clamps and steps highlight skipping disabled rows", () => {
    const enabled = [false, true, false, true];
    expect(clampedHighlight(0, enabled)).toBe(1);
    expect(clampedHighlight(2, enabled)).toBe(3);
    expect(clampedHighlight(1, [false, false])).toBeNull();
    expect(stepHighlight(1, 1, enabled)).toBe(3);
    expect(stepHighlight(3, 1, enabled)).toBe(3);
    expect(stepHighlight(3, -1, enabled)).toBe(1);
    expect(stepHighlight(1, -1, enabled)).toBe(1);
  });

  it("maps 1..9 number shortcuts to enabled rows", () => {
    const enabled = [false, true, true, false, true];
    expect(numberKeyRow(1, enabled)).toBe(1);
    expect(numberKeyRow(2, enabled)).toBe(2);
    expect(numberKeyRow(3, enabled)).toBe(4);
    expect(numberKeyRow(4, enabled)).toBeNull();
    expect(numberKeyRow(0, enabled)).toBeNull();
  });

  it("matches multi-word queries and detects informative model ids", () => {
    expect(modelSearchMatches("", "Claude Opus")).toBe(true);
    expect(modelSearchMatches("opus 4", "Claude Opus 4.6", "claude-opus-4-6")).toBe(true);
    expect(modelSearchMatches("sonnet", "Claude Opus 4.6")).toBe(false);
    expect(idAddsToName("claude-opus-5-5", "Claude Opus 5.5")).toBe(false);
    expect(idAddsToName("claude-opus-4-1-20250805", "Claude Opus 4.1")).toBe(true);
  });
});
