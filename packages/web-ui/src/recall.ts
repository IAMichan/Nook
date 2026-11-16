// Up in an empty message field brings back an earlier question, like a shell's history; Down goes forward again.

/** The questions you asked in this conversation, newest first, once each. */
export function askedBefore(messages: readonly { fromUser: boolean; text: string }[]): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i];
    const text = m.text.trim();
    if (!m.fromUser || !text || seen.has(text)) continue;
    seen.add(text);
    out.push(m.text);
  }
  return out;
}

/**
 * Where Up and Down are in the history. `step` returns the text to put in the field, or null when the key should do
 * what it always does (move the caret): a field with your own words in it is never overwritten.
 */
export class Recall {
  index = -1;

  reset() {
    this.index = -1;
  }

  /** Whether a recalled question is in the field unchanged; then Up and Down keep stepping wherever the caret is. */
  stepping(history: readonly string[], text: string) {
    return this.index >= 0 && text === history[this.index];
  }

  step(history: readonly string[], text: string, direction: 1 | -1): string | null {
    if (!history.length) return null;
    if (this.index === -1 ? text.trim() !== "" || direction === -1 : text !== history[this.index]) return null;
    const next = this.index + direction;
    if (next >= history.length) return null;
    this.index = next;
    return next < 0 ? "" : history[next];
  }
}
