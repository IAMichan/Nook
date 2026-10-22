import { describe, expect, it } from "vitest";
import { conversationMarkdown } from "./conversation-export";

describe("conversationMarkdown", () => {
  it("preserves message order, Markdown and attachment names", () => {
    expect(conversationMarkdown({ title: "Project notes", messages: [
      { id: "q", fromUser: true, streaming: false, text: "Summarize this.", attachment: "notes.txt" },
      { id: "a", fromUser: false, streaming: false, text: "- **Ship** the update.", attachment: null },
    ] })).toBe("# Project notes\n\n## You\n\nAttachment: notes.txt\n\nSummarize this.\n\n## Nook\n\n- **Ship** the update.");
  });

  it("copies the visible streaming answer and ignores stale streams on finished messages", () => {
    expect(conversationMarkdown({ title: "Live", messages: [
      { id: "done", fromUser: false, streaming: false, text: "Final answer", attachment: null },
      { id: "live", fromUser: false, streaming: true, text: "Earlier", attachment: null },
    ] }, { done: "Stale", live: "Visible answer so far" })).toBe("# Live\n\n## Nook\n\nFinal answer\n\n## Nook\n\nVisible answer so far");
  });

  it("uses saved text when no stream update has arrived", () => {
    expect(conversationMarkdown({ title: "Live", messages: [
      { id: "a", fromUser: false, streaming: true, text: "Saved answer", attachment: null },
    ] })).toContain("Saved answer");
  });
});
