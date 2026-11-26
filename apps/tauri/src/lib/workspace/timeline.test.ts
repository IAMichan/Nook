import { describe, expect, it } from "vitest";
import type { EventKind, EventState, RunEvent } from "./api";
import {
  backgroundCommandOutputFile, backgroundCommandTail, backgroundLaunchNotice, blocks, categoryOf, containers, countLabel,
  currentBackgroundCommands, currentSubagents, duration, firstFailure, group, headline, isBackgroundCommand,
  isBackgroundNotice, isSubagentLaunch, lastTurn, listBackgroundCommands, listSubagents, live, nextMatch, orderedBackgroundCommands,
  parts, planFileName, planPreview, planTitle, previousMatch, readableName, search, sentence, split, tally, toolLabel,
} from "./timeline";

describe("tool names", () => {
  it("read MCP tools as words", () => {
    expect(toolLabel("mcp__bestanden-mappen__move_file")).toBe("Move file");
    expect(toolLabel("mcp__claude_ai_Google_Drive__searchFiles")).toBe("Search files");
    expect(toolLabel("Bash")).toBe("Bash");
    expect(toolLabel("mcp__server")).toBe("mcp__server");
    expect(readableName("get_URL")).toBe("Get URL");
    expect(readableName("Google_Drive")).toBe("Google Drive");
    expect(readableName("Move file")).toBe("Move file");
  });
});

let n = 0;
const start = Date.parse("2026-01-01T00:00:00Z");
function event(kind: EventKind, text: string, o: { tool?: string; detail?: string; output?: string; state?: EventState; at?: number } = {}): RunEvent {
  n += 1;
  return {
    id: `e${n}`,
    date: new Date(start + (o.at ?? 0) * 1000).toISOString(),
    kind,
    text,
    tool: o.tool,
    detail: o.detail,
    output: o.output,
    state: o.state,
  };
}

function finishedTurn(): RunEvent[] {
  return [
    event("user", "Fix de test"),
    event("thinking", "**Kijken** naar de test"),
    event("tool", "Bash · npm test", { tool: "Bash", state: "done", at: 5 }),
    event("tool", "Edit · App.swift", { tool: "Edit", detail: '{"file_path":"/p/App.swift"}', state: "done", at: 20 }),
    event("tool", "Edit · App.swift", { tool: "Edit", detail: '{"file_path":"/p/App.swift"}', state: "done", at: 30 }),
    event("assistant", "Opgelost.", { state: "done", at: 130 }),
    event("result", "2m 13s", { state: "done", at: 133 }),
  ];
}

describe("TimelinePresentation", () => {
  it("folds a finished turn between question and answer", () => {
    const b = blocks(finishedTurn(), false);
    expect(b.map((x) => x.type)).toEqual(["event", "fold", "event", "event"]);
    const fold = b[1];
    if (fold.type !== "fold") throw new Error();
    expect(fold.seconds).toBe(133);
    expect(fold.blocks.length).toBe(2);
    const tools = fold.blocks[1];
    if (tools.type !== "tools") throw new Error();
    expect(tools.events.length).toBe(3);
    expect(parts(tools.tally).map((p) => p.category)).toEqual(["command", "edit"]);
    expect(tools.tally.counts.edit).toBe(1);
    expect(tools.tally.failed).toBe(false);
    expect(sentence(tools.tally)).toBe("Ran 1 command and changed 1 file");
  });

  it("gives every block its own id", () => {
    const events = [...finishedTurn(), ...finishedTurn(), event("user", "Nog iets", { at: 300 }), event("tool", "Read · x", { tool: "Read" })];
    const ids = blocks(events, true).map((b) => b.id);
    expect(new Set(ids).size).toBe(ids.length);
  });

  it("does not fold running or troubled turns", () => {
    expect(blocks(finishedTurn(), true).some((b) => b.type === "fold")).toBe(false);
    const failed = finishedTurn();
    failed.splice(5, 0, event("error", "Rate limit", { at: 60 }));
    expect(blocks(failed, false).some((b) => b.type === "fold")).toBe(false);
    expect(blocks([...finishedTurn(), event("user", "Nog iets", { at: 200 })], true).some((b) => b.type === "fold")).toBe(true);
  });

  it("keeps errors apart and needs two tools for a group", () => {
    const b = group([
      event("tool", "Read · a", { tool: "Read" }),
      event("error", "kapot"),
      event("tool", "Grep · x", { tool: "Grep" }),
      event("thinking", "hmm"),
      event("tool", "run_shell_command · ls", { tool: "run_shell_command", state: "failed" }),
      event("thinking", "volgende stap"),
    ]);
    expect(b.length).toBe(6);
    expect(b.every((x) => x.type === "event")).toBe(true);
    const grouped = group([event("tool", "Grep · x", { tool: "Grep" }), event("tool", "ls", { tool: "run_shell_command", state: "failed" })]);
    expect(grouped.length).toBe(1);
    const g = grouped[0];
    if (g.type !== "tools") throw new Error();
    expect(g.tally.failed).toBe(true);
    expect(parts(g.tally).map((p) => p.category)).toEqual(["command", "search"]);
  });

  it("shows the live activity", () => {
    const events = [...finishedTurn().slice(0, -2), event("tool", "Bash · pnpm build", { tool: "Bash", state: "running", at: 140 })];
    expect(live(events)).toEqual({ tool: "Bash · pnpm build", thought: "Kijken" });
  });

  it("makes headlines", () => {
    expect(headline("**Plan maken**\nEerst de tests.")).toBe("Plan maken");
    expect(headline("Ik bekijk eerst de tests. Daarna de code.")).toBe("Ik bekijk eerst de tests.");
    expect(headline("kort")).toBe("kort");
  });

  it("knows tool categories and counts edited files", () => {
    expect(categoryOf("mcp__nook__terminal_run")).toBe("command");
    expect(categoryOf("mcp__nook__browser_read")).toBe("other");
    expect(categoryOf("shell")).toBe("command");
    expect(categoryOf("write_file")).toBe("edit");
    expect(categoryOf("Glob")).toBe("search");
    expect(categoryOf("TodoWrite")).toBe("other");
    const t = tally([event("fileChange", "a", { detail: "a" }), event("fileChange", "b", { detail: "b" }), event("fileChange", "a", { detail: "a" })]);
    expect(t.counts.edit).toBe(2);
  });

  it("maps events to the blocks that hide them", () => {
    const b = blocks(finishedTurn(), false);
    const keys = containers(b);
    const fold = b[1];
    if (fold.type !== "fold") throw new Error();
    const tools = fold.blocks[1];
    if (tools.type !== "tools") throw new Error();
    expect(keys[tools.events[0].id]).toEqual(["fold:" + fold.id, "group:" + tools.id]);
    expect(keys[b[0].id]).toBeUndefined();
  });

  it("sums up larger groups", () => {
    const t = tally([
      event("tool", "a", { tool: "Bash" }), event("tool", "b", { tool: "Read" }), event("tool", "c", { tool: "Grep" }), event("tool", "d", { tool: "Grep" }),
    ]);
    expect(sentence(t)).toBe("Ran 1 command, read 1 file and 2 more actions");
  });
});

describe("TimelineSearch", () => {
  const ev = (kind: EventKind, text: string, detail?: string, output?: string) => event(kind, text, { detail, output });

  it("handles empty queries and timelines", () => {
    expect(search([ev("user", "a")], "").state).toBe("idle");
    expect(search([ev("user", "a")], "  ").state).toBe("idle");
    expect(search([], "a").state).toBe("noResults");
  });

  it("ignores case and accents", () => {
    const r = search([ev("assistant", "Café CAFE cafe")], "cafe");
    expect(r.matches.map((m) => [m.start, m.end])).toEqual([[0, 4], [5, 9], [10, 14]]);
    expect(r.state).toBe("results");
  });

  it("searches fields with offsets", () => {
    const r = search([ev("tool", "run", "x foo", "foo foo")], "foo");
    expect(r.matches.map((m) => m.field)).toEqual(["detail", "output", "output"]);
    expect([r.matches[0].start, r.matches[0].end]).toEqual([2, 5]);
  });

  it("skips thinking unless asked", () => {
    const e = [ev("thinking", "hmm foo")];
    expect(search(e, "foo").state).toBe("noResults");
    expect(search(e, "foo", true).matches.length).toBe(1);
  });

  it("treats regex characters literally", () => {
    expect(search([ev("assistant", "a.b a+b (x) [y] a*")], ".").matches.length).toBe(1);
    expect(search([ev("assistant", "(x) [y]")], "(x)").matches.length).toBe(1);
    expect(search([ev("assistant", "aab")], ".*").state).toBe("noResults");
  });

  it("uses UTF-16 offsets", () => {
    const r = search([ev("assistant", "😀 hi 😀 hi")], "hi");
    expect(r.matches.map((m) => [m.start, m.end])).toEqual([[3, 5], [9, 11]]);
  });

  it("fails on a query that is too long", () => {
    expect(search([], "a".repeat(501)).state).toBe("failed");
  });

  it("navigates both ways and labels the count", () => {
    const r = search([ev("assistant", "a a a")], "a");
    expect(nextMatch(r, null)).toBe(0);
    expect(nextMatch(r, 1)).toBe(2);
    expect(nextMatch(r, 2)).toBe(0);
    expect(nextMatch(r, 2, false)).toBeNull();
    expect(previousMatch(r, null)).toBe(2);
    expect(previousMatch(r, 0)).toBe(2);
    expect(previousMatch(r, 0, false)).toBeNull();
    expect(previousMatch(r, 2)).toBe(1);
    expect(nextMatch({ state: "idle", matches: [] }, null)).toBeNull();
    expect(countLabel(r, 0)).toBe("1/3");
    expect(countLabel(r, 2)).toBe("3/3");
    expect(countLabel(r, null)).toBe("0/3");
    expect(countLabel({ state: "idle", matches: [] }, null)).toBe("0/0");
  });

  it("is fast on five thousand events", () => {
    const events = Array.from({ length: 5000 }, (_, i) => ev("assistant", `message number ${i} with some filler text`, undefined, `output ${i} needle`));
    const t = Date.now();
    expect(search(events, "needle").matches.length).toBe(5000);
    expect(Date.now() - t).toBeLessThan(5000);
  });
});

describe("plans, failures and durations", () => {
  it("finds the first failure", () => {
    const a = event("tool", "ok", { state: "done" });
    const b = event("tool", "kapot", { state: "failed" });
    expect(firstFailure([a, b, event("error", "x")])).toBe(b.id);
    expect(firstFailure([a])).toBeNull();
  });

  it("previews plans", () => {
    expect(planTitle("intro\n## Het plan\n- a")).toBe("Het plan");
    const long = Array.from({ length: 14 }, (_, i) => `- stap ${i}`).join("\n");
    expect(planPreview(long).endsWith("\n\n...")).toBe(true);
    expect(planPreview("- a\n\n")).toBe("- a");
    expect(planFileName("Plan: Voeg (knop) toe!")).toBe("plan-voeg-knop-toe.md");
    expect(planFileName("!!!")).toBe("plan.md");
  });

  it("formats durations like the Mac", () => {
    expect(duration(30)).toBe("< 1 min");
    expect(duration(12 * 60)).toBe("12 min");
    expect(duration(125 * 60)).toBe("2h 5m");
    expect(duration(120 * 60)).toBe("2h");
    expect(duration(72 * 3600)).toBe("3 d");
  });
});

describe("Subagents, background commands and wake turns (AG-73)", () => {
  it("extracts subagent launches and keeps them out of tool groups", () => {
    const sub = event("tool", "Task · Audit workspace", {
      tool: "Task",
      detail: JSON.stringify({ subagent_type: "Explore", description: "Audit workspace", prompt: "Check all files", run_in_background: true }),
      output: "Async agent launched successfully.\nagentId: a1b2",
      state: "running",
      at: 10,
    });
    const read1 = event("tool", "Read · a.ts", { tool: "Read", state: "done", at: 11 });
    const read2 = event("tool", "Read · b.ts", { tool: "Read", state: "done", at: 12 });

    expect(isSubagentLaunch(sub)).toBe(true);
    const list = listSubagents([sub, read1, read2]);
    expect(list.length).toBe(1);
    expect(list[0].kind).toBe("Explore");
    expect(list[0].title).toBe("Audit workspace");
    expect(list[0].prompt).toBe("Check all files");
    expect(list[0].background).toBe(true);
    expect(list[0].taskId).toBe("a1b2");
    expect(list[0].isRunning).toBe(true);
    expect(list[0].answer).toBeNull();

    const g = group([read1, sub, read2]);
    expect(g.map((b) => b.id)).toEqual([read1.id, sub.id, read2.id]);
  });

  it("extracts background commands, strips launch notes and orders running first", () => {
    const cmd1 = event("tool", "Bash · npm run dev", {
      tool: "Bash",
      detail: JSON.stringify({ command: "npm run dev", description: "Start dev server", run_in_background: true }),
      output: "Command running in background with ID: b3k9. Output is being written to: /tmp/claude/tasks/b3k9.output. Read on that file path. Ready on http://localhost:3000",
      state: "running",
      at: 15,
    });
    const cmd2 = event("tool", "Bash · cargo build", {
      tool: "Bash",
      detail: JSON.stringify({ command: "cargo build", run_in_background: true }),
      output: "Finished dev",
      state: "done",
      at: 20,
    });
    const cmd3 = event("tool", "Bash · pytest", {
      tool: "Bash",
      detail: JSON.stringify({ command: "pytest", run_in_background: true }),
      output: "1 failed",
      state: "failed",
      at: 25,
    });

    expect(isBackgroundCommand(cmd1)).toBe(true);
    const cmds = listBackgroundCommands([cmd2, cmd3, cmd1]);
    expect(cmds.length).toBe(3);
    expect(cmds[2].title).toBe("Start dev server");
    expect(cmds[2].command).toBe("npm run dev");
    expect(cmds[2].printed).toBe("Ready on http://localhost:3000");
    expect(cmds[2].outputFile).toBe("/tmp/claude/tasks/b3k9.output");
    expect(backgroundCommandOutputFile(cmd1.output)).toBe("/tmp/claude/tasks/b3k9.output");
    expect(backgroundCommandTail("line1\nline2\nline3\nline4\nline5", 3)).toBe("line3\nline4\nline5");

    const ordered = orderedBackgroundCommands(cmds);
    expect(ordered.map((c) => c.id)).toEqual([cmd1.id, cmd3.id, cmd2.id]);
  });

  it("joins wake turns into the user turn and folds intermediate wake results cleanly", () => {
    const timeline = [
      event("user", "Run background build and report", { at: 0 }),
      event("tool", "Bash · cargo build", {
        tool: "Bash",
        detail: JSON.stringify({ command: "cargo build", run_in_background: true }),
        state: "done",
        at: 5,
      }),
      event("assistant", "task-148 has been launched in the background. I will wait for it to complete before proceeding.", { at: 6 }),
      event("result", "6s", { state: "done", at: 6 }),
      event("system", "Wake", { tool: "wake", at: 30 }),
      event("tool", "Read · build.log", { tool: "Read", state: "done", at: 32 }),
      event("assistant", "The build succeeded with 0 warnings.", { state: "done", at: 35 }),
      event("result", "35s", { state: "done", at: 35 }),
    ];

    expect(backgroundLaunchNotice(timeline[2].text)).toEqual(["task-148"]);
    expect(isBackgroundNotice(timeline[2])).toBe(true);

    const turns = split(timeline);
    expect(turns.length).toBe(1);

    const b = blocks(timeline, false);
    expect(b.map((x) => x.type)).toEqual(["event", "fold", "event", "event"]);
    expect(b[2].type === "event" && b[2].event.text).toBe("The build succeeded with 0 warnings.");

    // currentSubagents and currentBackgroundCommands include running items from earlier turns
    expect(currentBackgroundCommands(timeline).length).toBe(1);
    expect(currentSubagents(timeline).length).toBe(0);
  });

  it("starts a new turn for PR news after a finished turn while keeping mid-turn news in place (#1601)", () => {
    const news = event("system", "PR acme/web#42: CI failed", { tool: "prwatch", at: 300 });
    const timeline = [
      ...finishedTurn(),
      news,
      event("tool", "Bash · gh pr view", { tool: "Bash", state: "done", at: 305 }),
      event("tool", "Bash · gh pr checks", { tool: "Bash", state: "done", at: 310 }),
      event("assistant", "Er hoeft niets aangepast te worden.", { state: "done", at: 320 }),
      event("result", "20s", { state: "done", at: 321 }),
    ];

    expect(split(timeline).length).toBe(2);
    expect(lastTurn(timeline)[0]?.id).toBe(news.id);

    const visibleAnswers = blocks(timeline, false)
      .filter((b): b is Extract<ReturnType<typeof blocks>[number], { type: "event" }> => b.type === "event" && b.event.kind === "assistant")
      .map((b) => b.event.text);
    expect(visibleAnswers).toEqual(["Opgelost.", "Er hoeft niets aangepast te worden."]);

    // News arriving before the turn has finished stays inside that running turn.
    const running = [...finishedTurn().slice(0, -2), news];
    expect(split(running).length).toBe(1);
  });
});

