import { describe, expect, it } from "vitest";
import { elapsedLabel, errorKind } from "./working";

describe("working indicator", () => {
  it("shows the time only once the answer takes a moment", () => {
    expect(elapsedLabel(1)).toBeNull();
    expect(elapsedLabel(3)).toBe("3s");
    expect(elapsedLabel(184)).toBe("3m 4s");
    expect(elapsedLabel(3720)).toBe("1h 2m");
  });

  it("explains an error by the fix it offers", () => {
    expect(errorKind({ kind: "openLocalServer", name: "Ollama" } as never)).toEqual({ kind: "server", name: "Ollama" });
    expect(errorKind({ kind: "reconnectBrain" } as never).kind).toBe("credentials");
    expect(errorKind(null).kind).toBe("generic");
  });
});
