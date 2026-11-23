// A poll in a chat (`ChatPoll` in core/chats/poll.rs, `ChatPoll` on the Mac): what a click on an option makes of your
// choice, and the poll with your vote shown at once, before the app confirms it.

export interface PollOption { text: string; votes: number; chosen: boolean; voters?: string[] | null }
export interface ChatPoll { question: string; options: PollOption[]; multiple: boolean; unknownCounts?: boolean | null }

/** Your choice after a click on `option`: one answer replaces it (a second click takes it back), more answers add or take off. */
export function choiceAfter(poll: ChatPoll, option: string): string[] {
  const now = poll.options.filter((o) => o.chosen).map((o) => o.text);
  if (now.includes(option)) return now.filter((o) => o !== option);
  return poll.multiple ? [...now, option] : [option];
}

/** The poll with `choice` as your vote: the counts move with it at once. */
export function voting(poll: ChatPoll, choice: string[]): ChatPoll {
  return {
    ...poll,
    options: poll.options.map((o) => {
      const now = choice.includes(o.text);
      return { ...o, chosen: now, votes: Math.max(0, o.votes + (now ? 1 : 0) - (o.chosen ? 1 : 0)) };
    }),
  };
}
