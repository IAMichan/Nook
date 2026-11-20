// The words a session opens its find bar on (`AppModel.viewModel.sessionFind` on the Mac): search everything sets them
// when it opens a session hit that matched in its transcript; the session's timeline takes them once it shows that run.
class SessionFind {
  /** The run (its id, without "run:") and the words, until the timeline has shown them. */
  pending = $state<{ run: string; words: string } | null>(null);

  open(run: string, words: string) {
    this.pending = { run, words };
  }

  /** The words for `run`, once: the find bar takes them. */
  take(run: string): string | null {
    if (this.pending?.run !== run) return null;
    const words = this.pending.words;
    this.pending = null;
    return words;
  }
}

export const sessionFind = new SessionFind();
