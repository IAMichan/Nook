// A message to show in the conversation on screen: search everything opens a hit right where it matched (the Mac's
// `openSearchHit` with the passage's anchor). The chat scrolls to it and marks it for a moment.
class ChatFocus {
  /** The message to bring into view, until the chat has shown it. */
  messageId = $state<string | null>(null);
  /** The message marked as found, for a moment after it was shown. */
  marked = $state<string | null>(null);

  show(messageId: string) {
    this.messageId = messageId;
  }
}

export const chatFocus = new ChatFocus();
