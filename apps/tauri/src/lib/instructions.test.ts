import { describe, expect, it } from "vitest";
import { partText, promptLine } from "./instructions";

describe("instructions", () => {
  it("shows a prompt's trigger before its text", () => {
    expect(promptLine({ trigger: "standup", body: "What did I do?" })).toBe("/standup  What did I do?");
    expect(promptLine({ trigger: "", body: "What did I do?" })).toBe("What did I do?");
  });
  it("keeps a long part to 4,000 characters", () => {
    expect(partText("x".repeat(5000))).toHaveLength(4001);
    expect(partText("short")).toBe("short");
  });
});
