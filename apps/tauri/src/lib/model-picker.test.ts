import { describe, expect, it } from "vitest";
import { clampHighlight, idAddsToName, modelMatches, numberKeyRow, placeHelp, railGroups, stepHighlight, type ModelPickerPlace } from "./model-picker";

describe("model picker", () => {
  it("groups the rail: this computer, then choices across agents, then agents", () => {
    const places: ModelPickerPlace[] = [
      { id: "claude", name: "Claude Code" },
      { id: "auto", name: "Auto", icon: "sparkles" },
      { id: "local", name: "On this computer", isLocal: true },
      { id: "codex", name: "Codex", detail: "work" },
    ];
    expect(railGroups(places).map((g) => g.map((p) => p.id))).toEqual([["local"], ["auto"], ["claude", "codex"]]);
    expect(railGroups([{ id: "claude", name: "Claude Code" }])).toHaveLength(1);
    expect(placeHelp(places[3])).toBe("Codex · work");
    expect(placeHelp({ id: "l", name: "On this computer", detail: "Ollama", isLocal: true })).toBe("On this computer");
  });

  it("matches a search in any name, ignoring case and spaces around it", () => {
    expect(modelMatches("", "x")).toBe(true);
    expect(modelMatches(" OPUS ", "Claude Opus 5.5", "claude-opus-5-5")).toBe(true);
    expect(modelMatches("sonnet", "Claude Opus 5.5")).toBe(false);
  });

  it("shows a model's id only when it adds to the name", () => {
    expect(idAddsToName("claude-opus-5-5", "Claude Opus 5.5")).toBe(false);
    expect(idAddsToName("claude-opus-4-1-20250805", "Claude Opus 4.1")).toBe(true);
    expect(idAddsToName("", "Anything")).toBe(false);
  });

  it("moves the highlight over rows that can be picked and stays at the ends", () => {
    const enabled = [false, true, false, true];
    expect(clampHighlight(0, enabled)).toBe(1);
    expect(clampHighlight(9, enabled)).toBe(3);
    expect(clampHighlight(2, [true, true, false])).toBe(1);
    expect(clampHighlight(0, [false])).toBeNull();
    expect(stepHighlight(1, 1, enabled)).toBe(3);
    expect(stepHighlight(3, 1, enabled)).toBe(3);
    expect(stepHighlight(3, -1, enabled)).toBe(1);
    expect(stepHighlight(null, 1, enabled)).toBe(1);
  });

  it("picks the nth model with Ctrl+number, a disabled one keeping its number", () => {
    const enabled = [true, false, true];
    expect(numberKeyRow(1, enabled)).toBe(0);
    expect(numberKeyRow(2, enabled)).toBeNull();
    expect(numberKeyRow(3, enabled)).toBe(2);
    expect(numberKeyRow(4, enabled)).toBeNull();
    expect(numberKeyRow(10, Array(12).fill(true))).toBeNull();
  });
});
