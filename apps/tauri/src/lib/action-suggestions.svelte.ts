// The steps Nook suggests from what a conversation says, shared by every place a conversation shows
// (`ChatActionSuggestions` on the Mac): asked once per newest message, a moment after it came, and only while nothing
// else goes on in the conversation; the backend decides whether it is worth a look (`suggest_actions`). Nothing runs
// until Do it (`run_suggested_actions`).
import { invoke } from "@tauri-apps/api/core";

export type Place = { kind: "nook" } | { kind: "chat"; app: string; name: string } | { kind: "agent"; name: string; title: string };
export interface Line { speaker: string; text: string; id: string }
export interface SuggestedStep { tool: string; input: unknown; summary: string }

/// The message a suggestion is for: the conversation and its newest message.
export interface Turn { conversation: string; message: string; date: string | null }

export type Run = { kind: "waiting" } | { kind: "running" } | { kind: "done"; text: string } | { kind: "failed"; text: string };

export interface SuggestionState {
  turn: Turn;
  looking: boolean;
  actions: SuggestedStep[];
  reason: string | null;
  run: Run;
}

/// How long a new message waits before Nook looks: a few quick messages in a row cost one look.
export const SETTLE_MS = 800;

/// What a run did, in one line: the one step's result, or how many ran.
export function outcome(results: string[], many: (n: number) => string): string {
  return results.length === 1 ? results[0] : many(results.length);
}

class ActionSuggestions {
  states = $state<Record<string, SuggestionState>>({});
  private timers = new Map<string, ReturnType<typeof setTimeout>>();

  /** The steps to show for a conversation now, if any. */
  shown(conversation: string): SuggestionState | null {
    const s = this.states[conversation];
    return s && s.actions.length ? s : null;
  }

  /**
   * A conversation is on screen with `turn` its newest message: a moment later Nook asks once. Called again whenever the
   * turn or `busy` changes; a turn already asked for is not asked again.
   */
  request(turn: Turn | null, busy: boolean, place: Place, lines: () => Line[], enabled: boolean) {
    if (!turn || busy || !enabled) return;
    const key = turn.conversation;
    const current = this.states[key];
    if (current && current.turn.message === turn.message) return;
    // A proposal that ran or failed belongs to its moment; one still waiting for you stays up.
    const keep = current && (current.run.kind === "waiting" || current.run.kind === "running");
    this.states[key] = {
      turn, looking: false,
      actions: keep ? current.actions : [], reason: keep ? current.reason : null, run: keep ? current.run : { kind: "waiting" },
    };
    clearTimeout(this.timers.get(key));
    this.timers.set(key, setTimeout(() => void this.look(key, turn, place, lines()), SETTLE_MS));
  }

  private async look(key: string, turn: Turn, place: Place, lines: Line[]) {
    if (this.states[key]?.turn.message !== turn.message) return;
    this.states[key].looking = true;
    const waiting = !!this.shown(key);
    const found = await invoke<{ actions: SuggestedStep[]; reason: string | null } | null>("suggest_actions", {
      request: { conversation: key, place, lines, date: turn.date, waiting },
    }).catch(() => null);
    const state = this.states[key];
    if (!state || state.turn.message !== turn.message) return;
    state.looking = false;
    if (found?.actions.length && state.run.kind !== "running") {
      state.actions = found.actions;
      state.reason = found.reason;
      state.run = { kind: "waiting" };
    }
  }

  /** Do it: the steps run one after another, as a plan in Nook Chat does. */
  async run(conversation: string, nookId: string | null, many: (n: number) => string) {
    const state = this.states[conversation];
    if (!state || !state.actions.length || state.run.kind !== "waiting") return;
    state.run = { kind: "running" };
    try {
      const results = await invoke<string[]>("run_suggested_actions", { nookId, steps: state.actions });
      if (this.states[conversation]?.run.kind === "running") this.states[conversation].run = { kind: "done", text: outcome(results, many) };
    } catch (e) {
      if (this.states[conversation]?.run.kind === "running") this.states[conversation].run = { kind: "failed", text: String(e) };
    }
  }

  /** The cross: the steps go without running (they are not offered again), or are put away once done. */
  dismiss(conversation: string) {
    const state = this.states[conversation];
    if (!state || state.run.kind === "running") return;
    state.actions = [];
    state.reason = null;
    state.run = { kind: "waiting" };
  }
}

export const actionSuggestions = new ActionSuggestions();
