// `nook://prompt?text=…&project=…&agent=…&model=…` (the shared `PromptLink`): opens New session with the task filled in
// and the named folder and agent picked when the computer offers them. It never starts by itself. Hidden characters are
// stripped, and an overlong task is refused rather than cut (a cut prompt changes meaning).
export const MAX_TEXT = 8000;

export interface PromptLink { text: string; project?: string; agent?: string; model?: string }

/** Control and format characters out (zero-width, bidi, soft hyphen, tags); newline and tab stay. */
export function sanitize(raw: string): string {
  return [...raw].filter((c) => c === "\n" || c === "\t" || !/[\p{Cc}\p{Cf}\p{Co}\p{Cn}\u2028\u2029]/u.test(c)).join("");
}

export function parsePromptLink(url: string): PromptLink | null {
  const m = /^nook:\/\/prompt\/?\?(.*)$/i.exec(url.trim());
  if (!m) return null;
  const first = new Map<string, string>();
  for (const part of m[1].split("&")) {
    const [k, v = ""] = part.split("=");
    try {
      const key = decodeURIComponent(k.replace(/\+/g, " "));
      if (!first.has(key)) first.set(key, decodeURIComponent(v.replace(/\+/g, " ")));
    } catch {
      return null;
    }
  }
  const text = sanitize(first.get("text") ?? "").trim();
  if (!text || [...text].length > MAX_TEXT) return null;
  const link: PromptLink = { text };
  const project = (first.get("project") ?? "").trim();
  if (project && project.length <= 512 && !project.includes("\\") && !project.split("/").includes("..") && sanitize(project) === project) link.project = project;
  const agent = (first.get("agent") ?? "").trim().toLowerCase();
  if (agent && agent.length <= 40 && /^[a-z0-9._-]+$/.test(agent)) link.agent = agent;
  const model = (first.get("model") ?? "").trim();
  if (model && model.length <= 100 && /^[A-Za-z0-9._:\/@+-]+$/.test(model)) link.model = model;
  return link;
}

/** The project a link names among the computer's: by name, or by the end of its path. */
export function projectFor<T extends { name: string; path: string }>(hint: string | undefined, projects: T[]): T | undefined {
  const h = hint?.replace(/^\/+|\/+$/g, "").toLowerCase();
  if (!h) return undefined;
  return projects.find((p) => p.name.toLowerCase() === h) ?? projects.find((p) => p.path.toLowerCase().endsWith("/" + h) || p.path.toLowerCase() === h);
}

/** The agent a link names: its exact id, else the one whose id starts with it (`claude` → `claude-code`). */
export function agentFor<T extends { id: string }>(hint: string | undefined, agents: T[]): T | undefined {
  if (!hint) return undefined;
  return agents.find((a) => a.id === hint) ?? agents.find((a) => a.id.startsWith(hint));
}
