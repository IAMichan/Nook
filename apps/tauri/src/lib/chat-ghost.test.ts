import { describe, expect, it } from "vitest";
import { acceptChatGhost, advanceChatGhost, shouldRequestChatCompletion } from "./chat-ghost";

describe("chat-ghost helpers (CH-61)", () => {
  it("checks completion eligibility", () => {
    const base = {
      draft: "See you ",
      caret: 8,
      isEditing: false,
      isWriting: false,
      isRecording: false,
      isNookCommand: false,
    };
    expect(shouldRequestChatCompletion(base)).toBe(true);
    expect(shouldRequestChatCompletion({ ...base, draft: "hi", caret: 2 })).toBe(false);
    expect(shouldRequestChatCompletion({ ...base, draft: "   a  b ", caret: 8 })).toBe(false);
    expect(shouldRequestChatCompletion({ ...base, caret: 4 })).toBe(false);
    expect(shouldRequestChatCompletion({ ...base, isEditing: true })).toBe(false);
    expect(shouldRequestChatCompletion({ ...base, isWriting: true })).toBe(false);
    expect(shouldRequestChatCompletion({ ...base, isRecording: true })).toBe(false);
    expect(shouldRequestChatCompletion({ ...base, isNookCommand: true })).toBe(false);
  });

  it("consumes matching typed prefix without discarding the rest of the ghost", () => {
    expect(advanceChatGhost("See you ", "See you tom", "tomorrow afternoon")).toBe("orrow afternoon");
    expect(advanceChatGhost("See you ", "See you next", "tomorrow afternoon")).toBe("");
    expect(advanceChatGhost("See you ", "See you", "tomorrow afternoon")).toBe("");
    expect(advanceChatGhost("See you ", "See you tomorrow", "tomorrow")).toBe("");
  });

  it("accepts next word on Tab and full completion on Shift+Tab", () => {
    const word = acceptChatGhost("I will ", "check it tonight", "word");
    expect(word.nextDraft).toBe("I will check ");
    expect(word.remainingGhost).toBe("it tonight");
    expect(word.consumedAll).toBe(false);

    const all = acceptChatGhost("I will ", "check it tonight", "all");
    expect(all.nextDraft).toBe("I will check it tonight");
    expect(all.remainingGhost).toBe("");
    expect(all.consumedAll).toBe(true);
  });
});
