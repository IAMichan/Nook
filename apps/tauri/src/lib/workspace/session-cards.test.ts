import { describe, expect, it } from "vitest";
import type { RunEvent, WorkspaceRun } from "./api";
import { blocks } from "./timeline";
import { namedProvider, pageHeight, suggestedConfig, suggestionOf } from "./session-cards";

const event = (kind: RunEvent["kind"], extra: Partial<RunEvent> = {}): RunEvent => ({ id: Math.random().toString(36).slice(2), date: new Date().toISOString(), kind, text: "", ...extra });

describe("session cards", () => {
  it("reads a suggestion from its event", () => {
    const e = event("system", { tool: "session_suggestion", text: "T", detail: JSON.stringify({ title: "T", prompt: "Do it", summary: "", agent: "codex", worktree: true }), state: "pending" });
    expect(suggestionOf(e)).toEqual({ title: "T", prompt: "Do it", summary: "", agent: "codex", worktree: true });
    expect(suggestionOf(event("system", { tool: "origin" }))).toBeNull();
    expect(suggestionOf(event("system", { tool: "session_suggestion", detail: "{" }))).toBeNull();
  });

  it("names agents by id or name", () => {
    const providers = [{ provider: "codex" as const, name: "Codex" }, { provider: "claude" as const, name: "Claude Code" }];
    expect(namedProvider("Claude Code", providers)).toBe("claude");
    expect(namedProvider("codex", providers)).toBe("codex");
    expect(namedProvider("", providers)).toBeNull();
  });

  it("clamps the page height", () => {
    expect(pageHeight(event("system", { output: "5000" }))).toBe(1200);
    expect(pageHeight(event("system", {}))).toBe(360);
    expect(pageHeight(event("system", { output: "10" }))).toBe(80);
  });

  it("starts a suggestion beside the session with matching defaults", () => {
    const run = {
      provider: "claude",
      profileId: "claude-work",
      model: "opus",
      effort: "high",
      permission: "acceptEdits",
      isolation: "folder",
      projectPath: "/p",
      workingDirectory: "/p",
      baseBranch: "main",
    } as unknown as WorkspaceRun;
    const s = { title: "T", prompt: "Do it", summary: "", agent: "", worktree: true };
    const same = suggestedConfig(s, run, "claude", ["ask", "acceptEdits"], {
      models: {},
      profiles: {},
      worktreeRoot: "/wt",
    });
    expect(same).toMatchObject({
      task: "Do it",
      profileId: "claude-work",
      model: "opus",
      effort: "high",
      isolation: "worktree",
      baseBranch: "main",
      worktreeRoot: "/wt",
      permission: "acceptEdits",
      projectPath: "/p",
    });

    const other = suggestedConfig(
      { ...s, worktree: null },
      run,
      "codex",
      ["ask", "acceptEdits"],
      {
        models: { codex: "gpt-5" },
        profiles: { codex: "codex-main" },
        efforts: { codex: "medium" },
        isolation: "worktree",
        permission: "ask",
        folderChoices: {
          "/p": {
            provider: "codex",
            mode: "agent",
            permission: "acceptEdits",
            isolation: "worktree",
            agents: { codex: { profileId: "codex-work", model: "gpt-5-codex", effort: "low" } },
          },
        },
      },
      "develop",
    );
    expect(other).toMatchObject({
      provider: "codex",
      profileId: "codex-work",
      model: "gpt-5-codex",
      effort: "low",
      isolation: "worktree",
      baseBranch: "develop",
      permission: "acceptEdits",
    });
  });

  it("keeps a card out of a finished turn's fold", () => {
    const card = event("system", { tool: "session_suggestion", detail: "{}" });
    const turn = [event("user", { text: "go" }), event("tool", { tool: "Read" }), card, event("tool", { tool: "Edit" }), event("assistant", { text: "done" }), event("result")];
    const list = blocks(turn, false);
    expect(list.map((b) => b.type)).toEqual(["event", "fold", "event", "event", "event"]);
    expect(list[3]).toMatchObject({ type: "event", id: card.id });
  });
});
