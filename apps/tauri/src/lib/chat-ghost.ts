// Inline ghost-completion state helpers for the chat reply composer (CH-61).
import { nextChunk } from "./autocomplete";

export interface CompletionEligibility {
  draft: string;
  caret: number;
  isEditing: boolean;
  isWriting: boolean;
  isRecording: boolean;
  isNookCommand: boolean;
}

/**
 * Whether we should ask the autocomplete model for an inline ghost suffix.
 * Requires at least 3 non-whitespace characters, caret at the very end, and no special composer mode.
 */
export function shouldRequestChatCompletion(input: CompletionEligibility): boolean {
  if (input.isEditing || input.isWriting || input.isRecording || input.isNookCommand) return false;
  if (input.caret !== input.draft.length) return false;
  return input.draft.replace(/\s/g, "").length >= 3;
}

/**
 * Updates an active ghost suffix after the user types or deletes characters.
 * Typing characters that match the prefix of `currentGhost` consumes that prefix smoothly
 * without clearing the remaining suggestion; any other edit clears the ghost.
 */
export function advanceChatGhost(previousDraft: string, nextDraft: string, currentGhost: string): string {
  if (!currentGhost) return "";
  if (nextDraft.length <= previousDraft.length) return "";
  if (!nextDraft.startsWith(previousDraft)) return "";
  const typed = nextDraft.slice(previousDraft.length);
  if (!currentGhost.startsWith(typed)) return "";
  return currentGhost.slice(typed.length);
}

/**
 * Accepts either the next word chunk (`Tab`) or the entire inline ghost suffix (`Shift+Tab`).
 */
export function acceptChatGhost(
  draft: string,
  ghost: string,
  mode: "word" | "all",
  punctuationWithWord = true,
  trailingSpace = true,
): { nextDraft: string; remainingGhost: string; consumedAll: boolean } {
  if (!ghost) return { nextDraft: draft, remainingGhost: "", consumedAll: true };
  if (mode === "all") {
    return { nextDraft: draft + ghost, remainingGhost: "", consumedAll: true };
  }
  const chunk = nextChunk(ghost, punctuationWithWord, trailingSpace);
  const taken = chunk || ghost;
  const rest = ghost.slice(taken.length);
  const consumedAll = !rest.trim();
  return {
    nextDraft: draft + taken,
    remainingGhost: consumedAll ? "" : rest,
    consumedAll,
  };
}
