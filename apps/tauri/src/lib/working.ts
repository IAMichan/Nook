// What Nook is doing while it answers, as an agent session shows it (the Mac's `TypingIndicator`): the current step,
// and how long the answer has been going once it takes a moment. And the calm card for an answer that could not be
// made (`ChatErrorCard`): what happened in plain words, the fix, and the raw message behind Details.
import type { Recovery } from "./brain";

/// "12s", "3m 4s", "1h 2m"; nothing for the first three seconds, so a quick answer does not flash a timer.
export function elapsedLabel(seconds: number): string | null {
  if (!(seconds >= 3)) return null;
  const total = Math.round(seconds);
  if (total < 60) return `${total}s`;
  const minutes = Math.floor(total / 60);
  if (minutes < 60) return `${minutes}m ${total % 60}s`;
  return `${Math.floor(minutes / 60)}h ${minutes % 60}m`;
}

/// Which explanation an error card gives, by the fix it offers.
export type ErrorKind = { kind: "chooseModel" } | { kind: "server"; name: string } | { kind: "credentials" } | { kind: "generic" };

export function errorKind(recovery: Recovery | null | undefined): ErrorKind {
  switch (recovery?.kind) {
    case "chooseModel":
      return { kind: "chooseModel" };
    case "openLocalServer":
      return { kind: "server", name: recovery.name };
    case "reconnectBrain":
    case "reconnectConnection":
      return { kind: "credentials" };
    default:
      return { kind: "generic" };
  }
}
