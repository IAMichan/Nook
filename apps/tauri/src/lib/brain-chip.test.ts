import { describe, expect, it } from "vitest";
import { models, pillText, placeOf, places, toggleFavorite, loadFavorites } from "./brain-chip";
import type { ProviderInfo } from "./types";

const p = (id: string, title: string, isLocal: boolean, needsKey: boolean, suggestedModels: string[] = [], defaultModel = ""): ProviderInfo =>
  ({ id, title, isLocal, needsKey, keyPlaceholder: "", keyUrl: "", defaultModel, suggestedModels }) as ProviderInfo;

const providers = [
  p("claude", "Claude", false, true, ["claude-haiku-5-5"], "claude-haiku-5-5"),
  p("claudeCode", "Claude Code (je abonnement)", false, false, ["haiku", "sonnet", "opus"], "haiku"),
  p("ollama", "Ollama (op deze computer)", true, false, [], "llama3.2"),
];

describe("brain chip", () => {
  it("names the model, and the agent or service it goes through", () => {
    expect(pillText({ provider: "ollama", providerModels: { ollama: "qwen3.5:9b" } }, providers, "first model")).toBe("qwen3.5:9b");
    expect(pillText({ provider: "claudeCode", providerModels: {} }, providers, "")).toBe("Claude Code · haiku");
    expect(pillText({ provider: "claude", providerModels: { claude: "claude-opus-5-5" } }, providers, "")).toBe("Claude · claude-opus-5-5");
  });

  it("puts this computer first, then the agents, and opens where the brain is", () => {
    expect(places(providers, "On this computer").map((x) => x.id)).toEqual(["local", "claudeCode"]);
    expect(placeOf({ provider: "claudeCode" }, providers)).toBe("claudeCode");
    expect(placeOf({ provider: "claude" }, providers)).toBe("local");
  });

  it("lists, searches and stars models", () => {
    const servers = [{ server: "ollama" as const, name: "llama3.2" }, { server: "lmstudio" as const, name: "gemma-3" }];
    const local = models("local", { provider: "ollama", providerModels: { ollama: "llama3.2" } }, providers, servers, "", new Set(["gemma-3"]));
    expect(local.map((m) => m.id)).toEqual(["gemma-3", "llama3.2"]);
    expect(local[1].chosen).toBe(true);
    expect(local[0].trailing).toBe("LM Studio");
    expect(models("local", { provider: "ollama", providerModels: {} }, providers, servers, "gem", new Set()).map((m) => m.id)).toEqual(["gemma-3"]);
    const agent = models("claudeCode", { provider: "claudeCode", providerModels: { claudeCode: "claude-opus-4-1" } }, providers, [], "", new Set());
    expect(agent.map((m) => m.id)).toEqual(["haiku", "sonnet", "opus", "claude-opus-4-1"]);
    expect(agent[3].chosen).toBe(true);
  });

  it("keeps favourites per place", () => {
    const store = new Map<string, string>();
    const storage = { getItem: (k: string) => store.get(k) ?? null, setItem: (k: string, v: string) => void store.set(k, v) };
    toggleFavorite("local", "llama3.2", storage);
    expect([...loadFavorites("local", storage)]).toEqual(["llama3.2"]);
    expect(loadFavorites("claudeCode", storage).size).toBe(0);
    toggleFavorite("local", "llama3.2", storage);
    expect(loadFavorites("local", storage).size).toBe(0);
  });
});
