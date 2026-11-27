import { describe, expect, it } from "vitest";
import {
  DEFAULT_AUTO_COMPACT_TOKENS,
  SIZE_COMPACTION_CHOICES,
  formatTildePath,
  isAdviceApplied,
  providerDisplayName,
  tuningAdviceDetail,
  type AppliedTuning,
  type TuningAdvice,
} from "./token-savings";

describe("token-savings helpers (AG-32)", () => {
  it("matches macOS SizeCompaction defaults and choices", () => {
    expect(DEFAULT_AUTO_COMPACT_TOKENS).toBe(350_000);
    expect([...SIZE_COMPACTION_CHOICES]).toEqual([0, 150_000, 250_000, 350_000, 500_000]);
  });

  it("formats POSIX and Windows home paths with a leading tilde while preserving URLs", () => {
    expect(formatTildePath("/Users/alex/.claude/settings.json", "/Users/alex")).toBe("~/.claude/settings.json");
    expect(formatTildePath("C:\\Users\\alex\\.claude\\settings.json", "C:\\Users\\alex\\")).toBe(
      "~\\.claude\\settings.json",
    );
    expect(formatTildePath("https://claude.ai/settings/connectors", "/Users/alex")).toBe(
      "https://claude.ai/settings/connectors",
    );
    expect(formatTildePath("/etc/hosts", "/Users/alex")).toBe("/etc/hosts");
  });

  it("tracks applied Claude Code tuning switches accurately", () => {
    const applied: AppliedTuning = {
      claudePlugins: ["sales@inline", "marketing@inline"],
      claudeNoConnectors: true,
    };
    const pluginAdvice: TuningAdvice = {
      id: "claude:unusedPlugins",
      provider: "claude",
      kind: "unusedPlugins",
      items: ["sales@inline"],
      kept: [],
      characters: 1600,
      tokens: 400,
      location: "/Users/alex/.claude/settings.json",
      snippet: null,
      appliesInNook: true,
    };
    const partialPluginAdvice: TuningAdvice = {
      ...pluginAdvice,
      items: ["sales@inline", "other@inline"],
    };
    const connectorAdvice: TuningAdvice = {
      ...pluginAdvice,
      id: "claude:cloudConnectors",
      kind: "cloudConnectors",
      items: ["claude.ai Gmail"],
    };
    const codexAdvice: TuningAdvice = {
      ...pluginAdvice,
      id: "codex:servers",
      provider: "codex",
      kind: "servers",
      appliesInNook: false,
    };

    expect(isAdviceApplied(applied, pluginAdvice)).toBe(true);
    expect(isAdviceApplied(applied, partialPluginAdvice)).toBe(false);
    expect(isAdviceApplied(applied, connectorAdvice)).toBe(true);
    expect(isAdviceApplied(applied, codexAdvice)).toBe(false);
  });

  it("renders multi-line detail matching macOS TuningAdviceRow", () => {
    const advice: TuningAdvice = {
      id: "claude:cloudConnectors",
      provider: "claude",
      kind: "cloudConnectors",
      items: ["claude.ai Gmail"],
      kept: ["claude.ai Claude Docs"],
      characters: 2000,
      tokens: 500,
      location: "/Users/alex/.claude/settings.json",
      snippet: null,
      appliesInNook: false,
    };
    const detail = tuningAdviceDetail(advice, "/Users/alex");
    expect(detail).toContain("claude.ai Gmail");
    expect(detail).toContain("500");
    expect(detail).toContain("claude.ai Claude Docs");
    expect(detail).toContain("~/.claude/settings.json");
    expect(providerDisplayName("claude")).toBe("Claude Code");
  });
});
