// Up in an empty message field brings back an earlier question, like a shell's history.

/// The questions you asked in this Nook, newest first, once each.
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
