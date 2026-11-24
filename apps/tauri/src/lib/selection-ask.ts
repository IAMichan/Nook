// Asking Nook about words selected anywhere in Nook (`SelectionAsk` on the Mac, apps/macos/Services/SelectionAsk.swift):
// select a line of a message, an agent's answer or a pull request, and a small bar above the selection answers,
// explains or translates it in a card beside it, without opening the chat. The card is an ordinary Nook conversation
// (asked through the same `ask` command as the chat), so it is in the Nooks list afterwards and can go on there.
//
// This file holds the parts without the DOM: which selections are offered, what Nook is asked, and where the bar goes.
// `components/SelectionAsk.svelte` watches the selection and draws the bar and the card.

/// What the bar's buttons ask.
export type SelectionMode = "answer" | "explain" | "translate";

export const MODES: SelectionMode[] = ["answer", "explain", "translate"];

/// A longer selection is cut here: the question should be about a passage, not a whole document.
export const CHARACTER_LIMIT = 4000;
/// Fewer letters than this is a stray click or a single character, not something to ask about.
export const MINIMUM_LENGTH = 2;

/// Line separators as line breaks and the edges trimmed (`ComposerQuotes.normalize`).
export function normalize(raw: string): string {
  return raw.replace(/\u2028/g, "\n").replace(/\r\n/g, "\n").trim();
}

/// The selection as it is asked about, cut at `CHARACTER_LIMIT`; null when there is nothing to ask about (only spaces
/// or punctuation, or a single character).
export function offered(raw: string): string | null {
  const clean = normalize(raw);
  const chars = [...clean];
  if (chars.length < MINIMUM_LENGTH || !/[\p{L}\p{N}]/u.test(clean)) return null;
  if (chars.length <= CHARACTER_LIMIT) return clean;
  return chars.slice(0, CHARACTER_LIMIT - 1).join("").trim() + "…";
}

/// The selection formatted as a Markdown blockquote (`> line`).
export function formatQuote(selection: string): string {
  return normalize(selection).split("\n").map((line) => "> " + line).join("\n");
}

/// Appends a quoted selection to an agent composer's draft, ready to type underneath (`ComposerQuotes` on the Mac).
export function appendQuote(draft: string, selection: string): string {
  const quote = formatQuote(selection);
  const existing = draft.replace(/\s+$/, "");
  return existing ? `${existing}\n\n${quote}\n\n` : `${quote}\n\n`;
}

/// The message Nook gets (and the chat shows): the selection as a Markdown quote, then what to do with it.
export function message(selection: string, instruction: string): string {
  return [formatQuote(selection), instruction.trim()].filter(Boolean).join("\n\n");
}

/// Whether a mouse-up ends a deliberate selection: a drag, or a double or triple click. A plain click leaves the
/// selection the page already had, which must not bring the bar back with every click.
export function isDeliberate(down: { x: number; y: number }, up: { x: number; y: number }, clicks: number): boolean {
  return clicks >= 2 || Math.hypot(up.x - down.x, up.y - down.y) > 3;
}

export interface Rect {
  left: number;
  top: number;
  width: number;
  height: number;
}

/// Where a box of `size` goes for a selection at `anchor` (window pixels, y going down): centred above it with `gap`
/// to spare (the bar), or under it with `below` (the card, which grows downwards and leaves the selection in sight); on
/// the other side when there is no room, and always inside `visible` (the window).
export function origin(
  size: { width: number; height: number },
  anchor: Rect,
  visible: Rect,
  below = false,
  gap = 8,
): { x: number; y: number } {
  const bottom = visible.top + visible.height;
  const above = anchor.top - gap - size.height;
  const under = anchor.top + anchor.height + gap;
  let y: number;
  if (below) y = under + size.height <= bottom ? under : above;
  else y = above >= visible.top ? above : under;
  y = Math.min(Math.max(y, visible.top), bottom - size.height);
  y = Math.max(y, visible.top);
  const right = visible.left + visible.width;
  let x = anchor.left + anchor.width / 2 - size.width / 2;
  x = Math.min(Math.max(x, visible.left + gap), right - size.width - gap);
  x = Math.max(x, visible.left);
  return { x: Math.round(x), y: Math.round(y) };
}

/// The smallest piece of the DOM this needs: `closest` (an Element) or none (a text node's parent is looked up first).
export interface ElementLike {
  closest(selector: string): unknown;
}

/// Where the bar never offers itself: inside a field (where selecting is editing), inside the bar or card itself, or
/// in a part of the page that opts out.
export const SKIP_SELECTOR = "input, textarea, select, [contenteditable]:not([contenteditable='false']), .selection-ask, [data-no-selection-ask]";

export function skips(element: ElementLike | null | undefined): boolean {
  return !element || element.closest(SKIP_SELECTOR) != null;
}

/// What a selection looks like to the bar: its text, whether it is collapsed, and where both ends are.
export interface SelectionSnapshot {
  text: string;
  collapsed: boolean;
  start: ElementLike | null;
  end: ElementLike | null;
}

/// The words the bar is about, or null when it should not show: Selection Ask is off, nothing (worth asking about) is
/// selected, or either end of the selection is in a field or in the bar and card.
export function wanted(enabled: boolean, s: SelectionSnapshot | null): string | null {
  if (!enabled || !s || s.collapsed) return null;
  if (skips(s.start) || skips(s.end)) return null;
  return offered(s.text);
}

// MARK: Messages in a conversation (`SelectionAsk.contextRange`, `chatNote` on the Mac)

/// How many messages before a selection go with it as context, and how many after it (the answer it got).
export const CONTEXT_BEFORE = 20;
export const CONTEXT_AFTER = 3;

/// The messages that go with a selection from message `first` through `last` of `count` (indices, oldest first).
export function contextRange(first: number, last: number, count: number): [number, number] {
  return [Math.max(Math.min(first, last) - CONTEXT_BEFORE, 0), Math.min(Math.max(first, last) + CONTEXT_AFTER, count - 1)];
}

/// Added to the hidden note for a selection in a conversation: the messages around it, as material, never as
/// instructions. `you` is how the lines mark the user's own messages. Written in English for the brain, as the Mac's.
export function chatNote(contact: string, transcript: string, you: string): string {
  const withWho = contact ? ` with ${contact}` : "";
  return `The selection comes from the user's chat${withWho}. The messages around it follow, oldest first; lines from `
    + `"${you}" are the user's own. Use them to understand what the selection is about. When the selection is a `
    + `message someone sent the user, answer it the way the user could reply, from what the chat shows.\n${transcript}`;
}

/// The conversation as lines "Speaker: text" for the messages `range` covers.
export function transcript(messages: { speaker: string; text: string }[], range: [number, number]): string {
  return messages.slice(range[0], range[1] + 1).map((m) => `${m.speaker}: ${m.text.trim()}`).filter((l) => !l.endsWith(": ")).join("\n");
}

/// Builds the hidden conversation note for a selection spanning `firstId`..`lastId` inside a message list (Nook Chat or
/// the Chats tab). Returns null when either endpoint is missing or the surrounding messages carry no text.
export function chatContextFromRows(
  rows: { id: string; speaker: string; text: string }[],
  firstId: string,
  lastId: string,
  contact: string,
  you: string,
): string | null {
  const a = rows.findIndex((m) => m.id === firstId);
  const b = rows.findIndex((m) => m.id === lastId);
  if (a < 0 || b < 0) return null;
  const body = transcript(rows, contextRange(a, b, rows.length));
  return body ? chatNote(contact, body, you) : null;
}
