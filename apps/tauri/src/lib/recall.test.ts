import { describe, expect, it } from "vitest";
import { askedBefore, Recall } from "./recall";

describe("asked before", () => {
  it("lists your own questions newest first, once each", () => {
    const messages = [
      { fromUser: true, text: "first" },
      { fromUser: false, text: "answer" },
      { fromUser: true, text: "second" },
      { fromUser: true, text: "first" },
      { fromUser: true, text: "  " },
    ];
    expect(askedBefore(messages)).toEqual(["first", "second"]);
  });
});

describe("recall", () => {
  const history = ["newest", "older"];

  it("steps back from an empty field and forward again to empty", () => {
    const recall = new Recall();
    expect(recall.step(history, "", 1)).toBe("newest");
    expect(recall.step(history, "newest", 1)).toBe("older");
    expect(recall.step(history, "older", 1)).toBeNull();
    expect(recall.step(history, "older", -1)).toBe("newest");
    expect(recall.step(history, "newest", -1)).toBe("");
  });

  it("never overwrites your own words", () => {
    const recall = new Recall();
    expect(recall.step(history, "half a question", 1)).toBeNull();
    expect(recall.step(history, "", -1)).toBeNull();
    recall.step(history, "", 1);
    expect(recall.stepping(history, "newest")).toBe(true);
    expect(recall.step(history, "newest, edited", 1)).toBeNull();
    expect(recall.stepping(history, "newest, edited")).toBe(false);
  });
});
