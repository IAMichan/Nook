// Comments on a session's diff, sent to the agent as one message (`ReviewComments` on the Mac). No interface code, so
// tests use it on its own.

export interface ReviewComment {
  id: string;
  path: string;
  /** Line number in the new version of the file; null for a removed line. */
  line: number | null;
  /** The diff line it is about, with its +, - or space. */
  code: string;
  text: string;
}

/** The comments as one message for the agent (`ReviewComments.message`). */
export function reviewMessage(comments: ReviewComment[]): string {
  const blocks = comments.map((c) => {
    const line = c.line === null ? "" : ` line="${c.line}"`;
    return `<review_comment file="${c.path}"${line}>\n> ${c.code}\n${c.text.trim()}\n</review_comment>`;
  });
  return "Review comments on your changes. Address each one:\n\n" + blocks.join("\n\n");
}

/** Quotes `text` at the top of a draft (`ReviewComments.quote`). */
export function quote(text: string, draft: string): string {
  const quoted = text.trim().split("\n").map((l) => "> " + l).join("\n");
  const rest = draft.trim();
  return quoted + "\n\n" + rest;
}

/** Comments per session while you review; kept until sent or discarded. */
class ReviewStore {
  byRun = $state<Record<string, ReviewComment[]>>({});
  add(run: string, c: Omit<ReviewComment, "id">) {
    this.byRun[run] = [...(this.byRun[run] ?? []), { ...c, id: crypto.randomUUID() }];
  }
  remove(run: string, id: string) {
    this.byRun[run] = (this.byRun[run] ?? []).filter((c) => c.id !== id);
  }
  clear(run: string) {
    delete this.byRun[run];
  }
}

export const reviews = new ReviewStore();
