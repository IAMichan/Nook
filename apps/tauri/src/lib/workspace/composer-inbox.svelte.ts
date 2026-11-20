// Text waiting for a session's composer (`ComposerInbox` on the Mac): the side panel's Explain, Ask and Fix put a block
// here, and the session's composer takes it in above what you wrote.
class ComposerInbox {
  waiting = $state<Record<string, string[]>>({});

  add(text: string, session: string) {
    const key = session.replace(/^run:/, "");
    this.waiting[key] = [...(this.waiting[key] ?? []), text];
  }

  /** The blocks for a session, taken out of the inbox. */
  take(session: string): string[] {
    const key = session.replace(/^run:/, "");
    const list = this.waiting[key] ?? [];
    if (list.length) delete this.waiting[key];
    return list;
  }
}

export const composerInbox = new ComposerInbox();
