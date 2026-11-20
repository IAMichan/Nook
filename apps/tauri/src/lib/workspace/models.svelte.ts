// The models Nook offers each agent (`ModelManifest` on the Mac), read once from the backend.
import { invoke } from "@tauri-apps/api/core";

export interface CatalogModel {
  id: string;
  name: string;
  current: boolean;
  isNew: boolean;
  aliases: string[];
  default: boolean;
}

class ModelCatalog {
  byAgent = $state<Record<string, CatalogModel[]>>({});
  private loaded = false;

  load() {
    if (this.loaded) return;
    this.loaded = true;
    invoke<Record<string, CatalogModel[]>>("workspace_models").then((m) => (this.byAgent = m)).catch(() => (this.loaded = false));
  }

  /** The catalog entry `model` stands for, by its id or one of its aliases. */
  find(agent: string, model: string): CatalogModel | undefined {
    const m = model.trim().toLowerCase();
    if (!m) return undefined;
    return (this.byAgent[agent] ?? []).find((x) => x.id === m || x.aliases.includes(m));
  }
}

export const catalog = new ModelCatalog();

/// How a model reads on the composer's pill (`ComposerModelLabel.compact`): its name without the maker the agent's
/// logo beside it already shows ("Sonnet 5.5" under Claude Code). A name whose rest would not start with a word keeps it.
export function compactModelName(name: string, agent: string): string {
  const maker = agent.split(" ")[0];
  if (!maker || !name.startsWith(maker + " ")) return name;
  const rest = name.slice(maker.length + 1);
  return /^\p{L}/u.test(rest) ? rest : name;
}
