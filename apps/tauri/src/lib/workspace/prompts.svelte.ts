// Your saved prompts (`PromptLibrary` on the Mac), read from the backend and kept here for the composers' `/` list
// and "+" menu.
import { invoke } from "@tauri-apps/api/core";

export interface SavedPrompt {
  id: string;
  title: string;
  body: string;
  trigger: string;
  updatedAt: string;
}

export interface Variable { name: string; defaultValue: string }

const PATTERN = /\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?:\|([^}]*))?\}\}/g;

/** The variables in a body, in the order they first appear; a name used twice is asked once. */
export function variables(body: string): Variable[] {
  const out: Variable[] = [];
  for (const m of body.matchAll(PATTERN)) if (!out.some((v) => v.name === m[1])) out.push({ name: m[1], defaultValue: m[2] ?? "" });
  return out;
}

/** The body with each variable's value; one without a value gets its default, else stays empty. */
export function render(body: string, values: Record<string, string>): string {
  return body.replace(PATTERN, (_, name: string, fallback?: string) => values[name] || fallback || "");
}

/** A trigger as typed: the slash and anything but letters, digits, `-` and `_` taken out, lowercased. */
export const cleanTrigger = (raw: string) => [...raw.toLowerCase()].filter((c) => /[\p{L}\p{N}_-]/u.test(c)).join("");

class Prompts {
  list = $state<SavedPrompt[]>([]);
  private loaded = false;

  load(force = false) {
    if (this.loaded && !force) return;
    this.loaded = true;
    invoke<SavedPrompt[]>("workspace_prompts").then((p) => (this.list = p)).catch(() => (this.loaded = false));
  }

  async save(prompt: { id?: string; title: string; body: string; trigger: string }): Promise<boolean> {
    const kept = await invoke<boolean>("workspace_save_prompt", {
      prompt: { id: prompt.id ?? crypto.randomUUID(), title: prompt.title, body: prompt.body, trigger: prompt.trigger, updatedAt: new Date().toISOString() },
    });
    this.load(true);
    return kept;
  }

  async remove(id: string) {
    await invoke("workspace_delete_prompt", { id });
    this.load(true);
  }
}

export const prompts = new Prompts();
