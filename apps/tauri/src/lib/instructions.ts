// Settings › Instructions beyond the answer style (`InstructionStore` on the Mac): saved prompts, spaces and the
// context of the last answer (`nook_core::prompt_library`).
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

export interface SavedPrompt {
  id: string;
  title: string;
  body: string;
  trigger: string;
  updatedAt: string;
}

export interface NookSpace {
  id: string;
  name: string;
  instructions: string;
  attachments: string[];
  createdAt: string;
  /** How many conversations are filed in it. */
  conversations: number;
}

export type PartKind = "style" | "space" | "memory" | "lookedUp" | "overview";

export interface ContextBreakdown {
  parts: { kind: PartKind; text: string; tokens: number }[];
  budget: number;
  totalTokens: number;
  /** Percent of the model's window; null when the window is unknown. */
  fill: number | null;
}

export interface InstructionsView {
  prompts: SavedPrompt[];
  spaces: NookSpace[];
  lastContext: ContextBreakdown | null;
}

export const instructionsApi = {
  view: () => invoke<InstructionsView>("instructions_view"),
  savePrompt: (title: string, body: string, trigger: string) => invoke<boolean>("prompt_save", { title, body, trigger }),
  removePrompt: (id: string) => invoke<void>("prompt_remove", { id }),
  saveSpace: (name: string, instructions: string, id?: string) => invoke<void>("space_save", { id: id ?? null, name, instructions }),
  removeSpace: (id: string) => invoke<void>("space_remove", { id }),
  onChanged: (f: () => void): Promise<UnlistenFn> => listen("instructions-changed", f),
};

/** The second line of a prompt's row: its trigger, then its text (`/standup  What did I do…`). */
export function promptLine(prompt: Pick<SavedPrompt, "trigger" | "body">): string {
  return (prompt.trigger ? `/${prompt.trigger}  ` : "") + prompt.body;
}

/** A part's text as the inspector shows it: the first 4,000 characters. */
export function partText(text: string): string {
  return text.length > 4000 ? text.slice(0, 4000) + "…" : text;
}
