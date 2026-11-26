import { describe, expect, it } from "vitest";
import {
  apiTextProviders,
  formatTextGenerator,
  parseTextGenerator,
  textGeneratorProviderName,
  textGeneratorSummary,
} from "./text-generation";
import type { ProviderInfo } from "./types";

const sampleProviders: ProviderInfo[] = [
  {
    id: "claude",
    title: "Claude",
    isLocal: false,
    needsKey: true,
    isSubscription: false,
    cliCommand: null,
    loginCommand: null,
    keyPlaceholder: "sk-ant-...",
    keyUrl: "",
    defaultModel: "claude-haiku-5-5",
    suggestedModels: [],
  },
  {
    id: "claudeCode",
    title: "Claude Code",
    isLocal: false,
    needsKey: false,
    isSubscription: true,
    cliCommand: "claude",
    loginCommand: "claude",
    keyPlaceholder: "",
    keyUrl: "",
    defaultModel: "haiku",
    suggestedModels: [],
  },
  {
    id: "openai",
    title: "OpenAI",
    isLocal: false,
    needsKey: true,
    isSubscription: false,
    cliCommand: null,
    loginCommand: null,
    keyPlaceholder: "sk-...",
    keyUrl: "",
    defaultModel: "gpt-4.1-mini",
    suggestedModels: [],
  },
  {
    id: "ollama",
    title: "Ollama",
    isLocal: true,
    needsKey: false,
    isSubscription: false,
    cliCommand: null,
    loginCommand: null,
    keyPlaceholder: "",
    keyUrl: "",
    defaultModel: "",
    suggestedModels: [],
  },
];

describe("text-generation helpers (SV-65)", () => {
  it("filters out CLI subscription providers", () => {
    expect(apiTextProviders(sampleProviders).map((p) => p.id)).toEqual(["claude", "openai", "ollama"]);
  });

  it("round-trips agent and API generators including colons in model names", () => {
    const ollama = { kind: "api" as const, provider: "ollama" as const, model: "qwen2.5:7b-instruct" };
    expect(formatTextGenerator(ollama)).toBe("api:ollama:qwen2.5:7b-instruct");
    expect(parseTextGenerator(formatTextGenerator(ollama), sampleProviders)).toEqual(ollama);
    expect(formatTextGenerator({ kind: "agent" })).toBe("agent");
    expect(parseTextGenerator("agent", sampleProviders)).toEqual({ kind: "agent" });
  });

  it("falls back to agent for unknown, legacy, or subscription values", () => {
    expect(parseTextGenerator(undefined, sampleProviders)).toEqual({ kind: "agent" });
    expect(parseTextGenerator("automatic", sampleProviders)).toEqual({ kind: "agent" });
    expect(parseTextGenerator("api:claudeCode:haiku", sampleProviders)).toEqual({ kind: "agent" });
    expect(parseTextGenerator("api:nonexistent:foo", sampleProviders)).toEqual({ kind: "agent" });
  });

  it("formats provider display names and section summary", () => {
    expect(textGeneratorProviderName(sampleProviders[0], "Claude · API key")).toBe("Claude · API key");
    expect(textGeneratorProviderName(sampleProviders[2], "Claude · API key")).toBe("OpenAI");
    expect(textGeneratorSummary(undefined, sampleProviders, "Coding agent", "Claude · API key")).toBe("Coding agent");
    expect(
      textGeneratorSummary(
        { titles: "api:openai:gpt-4.1-mini", gitText: "api:openai:", nextPrompt: "api:openai:" },
        sampleProviders,
        "Coding agent",
        "Claude · API key",
      ),
    ).toBe("OpenAI");
    expect(
      textGeneratorSummary({ titles: "api:claude:" }, sampleProviders, "Coding agent", "Claude · API key"),
    ).toBe("Claude · API key (+2)");
  });
});
