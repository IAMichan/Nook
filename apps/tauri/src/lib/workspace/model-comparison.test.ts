import { describe, expect, it } from "vitest";
import type { NewRunConfig } from "./api";
import { configs, leader, MAX_MODELS, retrySelection, targets, toggling, type ComparisonTarget } from "./model-comparison";

const t = (provider: string, model: string, profileId = `${provider}-default`): ComparisonTarget => ({ provider: provider as ComparisonTarget["provider"], profileId, model });
const primary = t("claude", "opus");

const base: NewRunConfig = {
  title: "", task: "Fix the login bug", provider: "claude", profileId: "claude-default", model: "opus", mode: "agent",
  permission: "bypass", isolation: "folder", projectPath: "C:\\dev\\app", baseBranch: "main", branchName: "x",
  worktreeRoot: "", instructions: "", effort: "high",
} as NewRunConfig;

describe("model-comparison (ModelComparison)", () => {
  it("toggles extras and never grows past the cap", () => {
    let extras: ComparisonTarget[] = [];
    extras = toggling(t("codex", "gpt"), extras, primary);
    extras = toggling(t("gemini", "pro"), extras, primary);
    extras = toggling(t("claude", "sonnet"), extras, primary);
    expect(extras).toHaveLength(MAX_MODELS - 1);
    expect(toggling(t("cursor", "auto"), extras, primary)).toHaveLength(MAX_MODELS - 1);
    expect(toggling(t("codex", "gpt"), extras, primary).map((e) => e.provider)).toEqual(["gemini", "claude"]);
    expect(toggling(primary, [primary, t("codex", "gpt")], primary)).toEqual([t("codex", "gpt")]);
  });

  it("puts the chosen model first without doubles", () => {
    expect(targets(primary, [t("codex", "gpt"), primary, t("codex", "gpt")])).toEqual([primary, t("codex", "gpt")]);
  });

  it("makes one worktree config per target", () => {
    const list = configs(base, [primary, t("codex", "gpt")], (x) => x.model, (p) => (p === "codex" ? ["ask", "acceptEdits"] : ["bypass", "acceptEdits"]), (task) => task.slice(0, 13));
    expect(list.map((c) => c.title)).toEqual(["Fix the login · opus", "Fix the login · gpt"]);
    expect(list.every((c) => c.isolation === "worktree" && c.branchName === "")).toBe(true);
    expect(list[0].effort).toBe("high");
    expect(list[1].effort).toBeNull();
    expect(list[0].permission).toBe("bypass");
    expect(list[1].permission).toBe("acceptEdits");
  });

  it("keeps only what failed for another try", () => {
    const ok = { started: [{ target: primary, id: "a" }], failed: [] };
    expect(leader(ok)).toBe("a");
    expect(retrySelection(ok)).toBeNull();
    const partly = { started: [{ target: primary, id: "a" }], failed: [{ target: t("codex", "gpt"), message: "x" }, { target: t("gemini", "pro"), message: "y" }] };
    expect(retrySelection(partly)).toEqual({ primary: t("codex", "gpt"), extras: [t("gemini", "pro")] });
  });
});
