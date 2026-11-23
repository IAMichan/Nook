// Which brand a model or agent name points at, and its colors: the web side of `BrandLogo` and `AgentLogo` on the Mac
// (apps/macos/UI/Components/BrandLogo.swift, apps/macos/UI/Shared/AgentLogo.swift). The marks themselves are in
// brandLogos.ts, generated from the Mac's paths.

export type Brand =
  | "claude" | "openai" | "gemini" | "mistral" | "ollama" | "grok" | "groq" | "openrouter"
  | "deepseek" | "qwen" | "kimi" | "lmstudio" | "meta" | "gemma" | "opencode" | "cursor";

// In the Mac's order: "gemma" before "gemini", "claude" before anything else that might match.
const table: [string, Brand][] = [
  ["claude", "claude"], ["anthropic", "claude"], ["codex", "openai"], ["openai", "openai"], ["gpt", "openai"],
  ["gemma", "gemma"], ["gemini", "gemini"], ["mistral", "mistral"], ["mixtral", "mistral"], ["ollama", "ollama"],
  ["grok", "grok"], ["groq", "groq"], ["openrouter", "openrouter"], ["deepseek", "deepseek"], ["qwen", "qwen"],
  ["kimi", "kimi"], ["moonshot", "kimi"], ["lm studio", "lmstudio"], ["lmstudio", "lmstudio"], ["llama", "meta"],
  ["opencode", "opencode"], ["cursor", "cursor"],
];

/** The brand a model or agent name points at ("claude-haiku-5-5", "Qwen 3 (4B)", "Codex"), if there is a mark for it. */
export function brandFor(name: string): Brand | undefined {
  const lower = name.toLowerCase();
  return table.find(([word]) => lower.includes(word))?.[1];
}

/** A mark's fill: its brand color, a gradient's two stops, or null for the one-color marks that follow the text. */
export function brandFill(brand: Brand): string | [string, string] | null {
  switch (brand) {
    case "claude": return "#D97757";
    case "gemini": case "gemma": return ["#4F8BF7", "#9B72F2"];
    case "mistral": return "#FA520F";
    case "groq": return "#F55036";
    case "openrouter": return "#8B8EFF";
    case "deepseek": return "#5B7BFF";
    case "qwen": return "#7C78F5";
    case "kimi": return "#3A9BFF";
    case "meta": return "#1D9BF0";
    default: return null;
  }
}
