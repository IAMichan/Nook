// The backend's side of search everything (`commands/search.rs`): the text search over what only it holds, and the
// two steps of Search with AI.
import { invoke } from "@tauri-apps/api/core";
import type { BackendHit, BackendRequest } from "./search-everything";

/** One source as the brain reads it (`nook_core::search::Source`). */
export interface AISource { kind: string; title: string; subtitle: string; date: string; author: string; text: string }

export const searchApi = {
  search: (request: BackendRequest) => invoke<BackendHit[]>("search_everything", { request }),
  plan: (question: string) => invoke<string[]>("search_ai_plan", { question }),
  answer: (question: string, sources: AISource[]) => invoke<string>("search_ai_answer", { question, sources }),
  /** A call note as a new conversation with Nook; returns its id. */
  openNote: (id: string) => invoke<string>("search_open_note", { id }),
};
