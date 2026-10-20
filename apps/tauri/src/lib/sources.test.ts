import { describe, expect, it } from "vitest";
import type { RetrievalStep } from "./brain";
import { INTERRUPTED, UNKNOWN_ERROR, readableFailure, sourceGroups, sourcesSummary, statusText, visibleNotices } from "./sources";
import type { ChatMessage } from "./types";

function step(sourceTitle: string, outcome: RetrievalStep["outcome"], sourceId: string | null = null): RetrievalStep {
  return { id: sourceTitle + outcome.kind, tool: "t", sourceId, sourceTitle, query: "q", outcome, cached: false, references: [] };
}

function message(partial: Partial<ChatMessage>): ChatMessage {
  return {
    id: "m", fromUser: false, text: "", date: "", isError: false, streaming: false, status: "", images: [], sources: [],
    retrieval: [], references: [], contextSources: [], scopeLabel: "", notices: [], charts: [], mails: [], actions: [],
    planState: null, actionStates: [], actionIncluded: [], actionProblems: [], offers: [], recovery: null, attachment: null,
    ...partial,
  };
}

describe("sourceGroups", () => {
  it("puts unreadable sources first and gives every source a status", () => {
    const m = message({
      retrieval: [step("Mail", { kind: "empty" }), step("GitHub", { kind: "found", detail: 2 }, "github"), step("Notion", { kind: "failed", detail: "401" })],
      references: [
        { number: 1, sourceId: "github", title: "PR", detail: "" },
        { number: 2, sourceId: "github", title: "Issue", detail: "" },
      ],
      contextSources: ["Agenda"],
    });
    const groups = sourceGroups(m, false);
    expect(groups.map((g) => g.title)).toEqual(["Notion", "GitHub", "Agenda", "Mail"]);
    expect(groups.map(statusText)).toEqual(["Niet gelezen", "2 resultaten", "Meegestuurd als context", "Niets gevonden"]);
    expect(groups[0].reason).toBe("401");
    expect(sourcesSummary(groups, false)).toBe("2 bronnen gebruikt");
  });

  it("shows a search that never finished as interrupted once the answer is done", () => {
    const m = message({ retrieval: [step("Bestanden", { kind: "running" })] });
    expect(sourceGroups(m, true)[0].status).toBe("running");
    expect(sourcesSummary(sourceGroups(m, true), true)).toBe("Zoekt in je bronnen…");
    const done = sourceGroups(m, false)[0];
    expect(done.status).toBe("failed");
    expect(done.reason).toBe(INTERRUPTED);
    expect(sourcesSummary([done], false)).toBe("Niets gevonden");
  });
});

describe("readableFailure", () => {
  it("turns raw system errors into plain language", () => {
    expect(readableFailure("Swift.CancellationError")).toBe(INTERRUPTED);
    expect(readableFailure("gestopt")).toBe(INTERRUPTED);
    expect(readableFailure("The operation couldn’t be completed.")).toBe(UNKNOWN_ERROR);
    expect(readableFailure("")).toBe(UNKNOWN_ERROR);
    expect(readableFailure("Geen antwoord binnen 8 seconden.")).toBe("Geen antwoord binnen 8 seconden.");
  });
});

describe("visibleNotices", () => {
  it("drops the old per-source warnings that the sources card now shows", () => {
    const m = message({
      retrieval: [step("Notion", { kind: "failed", detail: "Notion weigerde de sleutel (401)." })],
      notices: [
        "Notion kon niet worden doorzocht: Notion weigerde de sleutel (401).",
        "Dit antwoord is daardoor mogelijk onvolledig.",
        "Onthouden: koffie zwart",
      ],
    });
    expect(visibleNotices(m)).toEqual(["Onthouden: koffie zwart"]);
    expect(visibleNotices(message({ notices: ["Dit antwoord is daardoor mogelijk onvolledig."] }))).toEqual([
      "Dit antwoord is daardoor mogelijk onvolledig.",
    ]);
  });
});
