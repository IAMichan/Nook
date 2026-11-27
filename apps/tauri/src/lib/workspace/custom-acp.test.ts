import { describe, expect, it } from "vitest";
import { filterAndSortRegistry, formatCommandLine, parseAcpCommand, shortSha256 } from "./custom-acp";
import type { RegistryEntry } from "./api";

describe("custom-acp helpers", () => {
  it("parses shell-quoted commands and rejects open quotes or trailing escapes", () => {
    expect(parseAcpCommand("npx -y @kiro/acp@1.2.3 --stdio")).toEqual({
      command: "npx",
      arguments: ["-y", "@kiro/acp@1.2.3", "--stdio"],
    });
    expect(parseAcpCommand('"/path with spaces/agent" --flag "hello world"')).toEqual({
      command: "/path with spaces/agent",
      arguments: ["--flag", "hello world"],
    });
    expect(parseAcpCommand("   ")).toBeNull();
    expect(parseAcpCommand('npx "unclosed')).toBeNull();
    expect(parseAcpCommand("npx --flag\\")).toBeNull();
  });

  it("formats command lines and short SHA-256 previews", () => {
    expect(formatCommandLine({ command: "uvx", arguments: ["agent==1.0.0", "--acp"] })).toBe("uvx agent==1.0.0 --acp");
    expect(shortSha256("a".repeat(64))).toBe("aaaaaaaaaaaa…");
    expect(shortSha256("short")).toBe("short");
  });

  it("sorts supported registry entries before unsupported ones and filters by query", () => {
    const mk = (id: string, name: string, supported: boolean, description = ""): RegistryEntry => ({
      id,
      name,
      version: "1.0.0",
      description,
      arguments: [],
      environment: {},
      supported,
    });
    const list = [
      mk("zeta", "Zeta", true, "Fast agent"),
      mk("alpha-bad", "Alpha Bad", false, "Unsupported"),
      mk("beta", "Beta", true, "Code helper"),
    ];
    expect(filterAndSortRegistry(list, "").map((e) => e.id)).toEqual(["beta", "zeta", "alpha-bad"]);
    expect(filterAndSortRegistry(list, "helper").map((e) => e.id)).toEqual(["beta"]);
    expect(filterAndSortRegistry(list, "alpha").map((e) => e.id)).toEqual(["alpha-bad"]);
  });
});
