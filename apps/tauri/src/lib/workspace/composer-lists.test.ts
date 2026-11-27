import { describe, expect, it } from "vitest";
import { continued } from "./composer-lists";

/** Types a line break at the end of `text` and runs the rule. */
const enter = (text: string) => continued(text + "\n", text.length + 1)?.text ?? null;

describe("composer-lists (ComposerLists)", () => {
  it("continues bullets, tasks and numbers", () => {
    expect(enter("- item")).toBe("- item\n- ");
    expect(enter("  * nested")).toBe("  * nested\n  * ");
    expect(enter("- [x] done")).toBe("- [x] done\n- [ ] ");
    expect(enter("7. step")).toBe("7. step\n8. ");
    expect(enter("07) step")).toBe("07) step\n08) ");
    expect(enter("9. last")).toBe("9. last\n10. ");
  });

  it("ends the list on an empty item", () => {
    expect(enter("- one\n- ")).toBe("- one\n");
    expect(enter("1. one\n2. ")).toBe("1. one\n");
  });

  it("leaves plain text alone", () => {
    expect(enter("just words")).toBeNull();
    expect(enter("-not a list")).toBeNull();
    expect(continued("abc", 2)).toBeNull();
  });

  it("works in the middle of the draft and places the caret", () => {
    const text = "- a\n\nafter";
    const result = continued(text, 4)!;
    expect(result.text).toBe("- a\n- \nafter");
    expect(result.caret).toBe(6);
  });
});
