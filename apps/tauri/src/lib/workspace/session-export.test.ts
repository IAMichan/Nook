import { describe, expect, it } from "vitest";
import { sessionFileName, sessionMarkdown } from "./session-export";
import type { RunEvent, WorkspaceRun } from "./api";

const run = { title: "Fix the login bug", model: "", resolvedModel: "claude-sonnet", branch: "fix-login", createdAt: "2026-11-04T10:00:00Z" } as WorkspaceRun;
const e = (kind: RunEvent["kind"], text: string): RunEvent => ({ id: text, date: "", kind, text });

describe("sessionMarkdown", () => {
  it("keeps the messages whole and folds the work between them", () => {
    const md = sessionMarkdown(run, [e("user", "Fix it"), e("thinking", "hmm"), e("tool", "Read `a.ts`"), e("tool", "Edit b.ts"), e("assistant", "Done."), e("result", "")], "Claude Code", "shop");
    expect(md).toBe(
      "# Fix the login bug\n\n_Claude Code · claude-sonnet · shop · fix-login · 2026-11-04_\n\n## You\n\nFix it\n\n" +
        "<details><summary>2 steps</summary>\n\n- `Read 'a.ts'`\n- `Edit b.ts`\n\n</details>\n\n## Claude Code\n\nDone.\n",
    );
  });

  it("names the file after the title", () => {
    expect(sessionFileName("Fix the login bug!")).toBe("fix-the-login-bug.md");
    expect(sessionFileName("???")).toBe("session.md");
  });
});
