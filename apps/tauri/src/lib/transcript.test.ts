import { describe, expect, it } from "vitest";
import { duration, mcpLabel, stepParts, tally, transcriptRows } from "./transcript";
import type { TimelineEntry } from "./companion";

const e = (id: string, kind: TimelineEntry["kind"], text = id, detail?: string, date = 0): TimelineEntry => ({ id, kind, text, detail, date, failed: false });

describe("transcript", () => {
  it("folds a finished turn into Worked for, keeping notices and the final answer", () => {
    const rows = transcriptRows([e("u", "user", "hi", undefined, 0), e("t", "tool", "npm test", "Bash", 10), e("x", "error", "boom", undefined, 20), e("a", "assistant", "done", undefined, 63)], false);
    expect(rows.map((r) => r.kind)).toEqual(["user", "fold", "notice", "answer"]);
    const fold = rows[1] as Extract<typeof rows[number], { kind: "fold" }>;
    expect(duration(fold.seconds!)).toBe("1m 3s");
    expect((rows[3] as { final: boolean }).final).toBe(true);
  });

  it("shows the running turn with its work and the step that runs now", () => {
    const rows = transcriptRows([e("u", "user"), e("r", "tool", "a.ts", "Read"), e("a", "assistant", "looking"), e("t", "tool", "npm test", "Bash")], true);
    expect(rows.map((r) => r.kind)).toEqual(["user", "working", "work", "answer", "live"]);
    expect((rows[4] as { entry: TimelineEntry }).entry.id).toBe("t");
  });

  it("says what steps did, as the iPhone does", () => {
    expect(stepParts(e("1", "tool", "npm test", "Bash"))).toEqual({ verb: "Ran", detail: "npm test", mono: true });
    expect(stepParts(e("2", "tool", "ls", "LS")).verb).toBe("Listed");
    expect(stepParts(e("3", "tool", "x", "mcp__github__create_issue")).verb).toBe("Github › Create issue");
    expect(mcpLabel("mcp__claude_ai_Linear__listIssues")).toBe("Linear › List issues");
    const t = tally([e("1", "tool", "a", "Bash"), e("2", "tool", "b", "Bash"), e("3", "change", "f.ts"), e("4", "change", "f.ts"), e("5", "tool", "r", "Read"), e("6", "tool", "q", "Grep")]);
    expect(t.sentence).toBe("Ran 2 commands, changed 1 file and 2 more actions");
    expect(tally([e("1", "tool", "a", "Read")]).sentence).toBe("Read 1 file");
    expect(duration(45)).toBe("45s");
    expect(duration(7200)).toBe("2h");
  });
});
