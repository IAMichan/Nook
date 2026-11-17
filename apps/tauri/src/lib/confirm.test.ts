import { describe, expect, it } from "vitest";
import { ConfirmQueue, type PendingConfirm } from "./confirm";

describe("ConfirmQueue", () => {
  it("resolves true on the red button and false on Cancel", async () => {
    const shown: (PendingConfirm | null)[] = [];
    const queue = new ConfirmQueue((front) => shown.push(front));
    const yes = queue.ask({ question: "Remove?", confirmTitle: "Remove" });
    expect(queue.front?.question).toBe("Remove?");
    queue.front!.answer(true);
    await expect(yes).resolves.toBe(true);
    const no = queue.ask({ question: "End?", confirmTitle: "End" });
    queue.front!.answer(false);
    await expect(no).resolves.toBe(false);
    expect(shown.map((f) => f?.question ?? null)).toEqual(["Remove?", null, "End?", null]);
  });

  it("shows a second question only when the first is answered", async () => {
    const queue = new ConfirmQueue();
    const first = queue.ask({ question: "First?", confirmTitle: "Yes" });
    const second = queue.ask({ question: "Second?", confirmTitle: "Yes" });
    expect(queue.front?.question).toBe("First?");
    queue.front!.answer(false);
    expect(queue.front?.question).toBe("Second?");
    queue.front!.answer(true);
    await expect(first).resolves.toBe(false);
    await expect(second).resolves.toBe(true);
    expect(queue.front).toBeNull();
  });

  it("ignores a second answer to the same question", async () => {
    // The dialog runs a button's action and then closes, which answers again with "no".
    const queue = new ConfirmQueue();
    const asked = queue.ask({ question: "Remove?", confirmTitle: "Remove" });
    const pending = queue.front!;
    pending.answer(true);
    pending.answer(false);
    await expect(asked).resolves.toBe(true);
  });
});

// The browser's own `confirm()` has no title, no Nook look and English buttons; everything asks through `ask()`.
const sources = import.meta.glob<string>(["../**/*.svelte", "../**/*.ts", "!../**/*.test.ts"], {
  query: "?raw",
  import: "default",
  eager: true,
});

describe("asking before what cannot be undone", () => {
  it("never uses window.confirm", () => {
    const offenders = Object.entries(sources)
      .filter(([, text]) => /(^|[^\w.$])(window\.)?confirm\s*\(\s*(tr\(|["'`])/m.test(text) || /window\.confirm\s*\(/.test(text))
      .map(([path]) => path);
    expect(offenders).toEqual([]);
  });
});
