import { describe, expect, it } from "vitest";
import { askedBefore } from "./recall";

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
