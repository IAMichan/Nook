import { describe, expect, it } from "vitest";
import { ToastQueue, TOAST_LIMIT, TOAST_SECONDS } from "./toast";

describe("toasts", () => {
  it("stack up, newest in front, and close by themselves", () => {
    const queue = new ToastQueue();
    queue.show("Opgeslagen", "success");
    queue.show("Push mislukt", "error", "remote rejected");
    expect(queue.shown.map((t) => t.title)).toEqual(["Opgeslagen", "Push mislukt"]);
    expect(queue.current?.title).toBe("Push mislukt");
    expect(queue.current?.detail).toBe("remote rejected");
    queue.advance(TOAST_SECONDS.success, false);
    expect(queue.shown.map((t) => t.title)).toEqual(["Push mislukt"]);
    queue.advance(TOAST_SECONDS.error, false);
    expect(queue.current).toBeNull();
  });

  it("show at most the limit at once, the rest wait their turn", () => {
    const queue = new ToastQueue();
    for (let i = 1; i <= TOAST_LIMIT + 1; i++) queue.show(`Melding ${i}`, "info");
    expect(queue.shown).toHaveLength(TOAST_LIMIT);
    queue.dismiss(queue.shown[0].id);
    expect(queue.shown).toHaveLength(TOAST_LIMIT);
    expect(queue.current?.title).toBe(`Melding ${TOAST_LIMIT + 1}`);
  });

  it("stay while hovered, and an error stays longer than a confirmation", () => {
    const queue = new ToastQueue();
    queue.show("Fout", "error");
    queue.advance(100, true);
    expect(queue.current?.title).toBe("Fout");
    queue.advance(TOAST_SECONDS.success, false);
    expect(queue.current?.title).toBe("Fout");
    expect(TOAST_SECONDS.error).toBeGreaterThan(TOAST_SECONDS.success);
  });

  it("show the same message once, and skip empty ones", () => {
    const queue = new ToastQueue();
    queue.show("Gekopieerd", "success");
    queue.advance(2, false);
    queue.show("Gekopieerd", "success");
    queue.advance(2, false);
    expect(queue.current?.title).toBe("Gekopieerd");
    queue.show("   ");
    queue.dismiss();
    expect(queue.current).toBeNull();
  });
});
