import { describe, expect, it } from "vitest";
import { attentionWord, canStop, looksLikePairingLink, sortSessions, type SessionDigest } from "./companion";

const session = (id: string, attention: string, updated: number): SessionDigest => ({
  id, title: id, agent: "Claude Code", attention, folder: "nook", updated, excerpt: "", items: [],
});

describe("companion", () => {
  it("puts what needs you first, then the newest", () => {
    const sorted = sortSessions([session("a", "idle", 9), session("b", "approval", 1), session("c", "working", 5), session("d", "idle", 10)]);
    expect(sorted.map((s) => s.id)).toEqual(["b", "c", "d", "a"]);
  });

  it("names the states like the iPhone app", () => {
    expect(attentionWord("approval")).toBe("Wacht op toestemming");
    expect(attentionWord("whatever")).toBe("Rust");
    expect(canStop("working")).toBe(true);
    expect(canStop("ready")).toBe(false);
  });

  it("recognises a pairing link", () => {
    expect(looksLikePairingLink(" nook://pair?h=a&p=1&k=x ")).toBe(true);
    expect(looksLikePairingLink("https://pair?h=a")).toBe(false);
  });
});
