// What the side panel hands to a session's agent (`SessionPrompts` on the Mac): the text that lands in its composer,
// for you to read and send. Only text, so every coding agent gets the same words. Whatever comes from outside (a
// title, a check's name) is marked as data for the agent, not as an order.

export interface SessionPullRequestRef { number: number; title: string; url: string; headBranch: string; baseBranch: string }

/** A block above what you already wrote, the way quotes land in the composer. */
export function merging(block: string, draft: string): string {
  const rest = draft.trim();
  return rest ? `${block.trim()}\n\n${rest}` : block.trim();
}

/** Text from outside inside a tag, with anything that would close the tag taken out. */
export function untrusted(tag: string, text: string): string {
  return `<${tag}>\n${text.split(`</${tag}`).join(`<\\/${tag}`).trim()}\n</${tag}>`;
}

const describe = (p: SessionPullRequestRef) => `pull request #${p.number} (${p.url}), branch ${p.headBranch} into ${p.baseBranch}`;
const title = (p: SessionPullRequestRef) => untrusted("pull_request_title", p.title);

export const explain = (p: SessionPullRequestRef) =>
  `Explain ${describe(p)}: what it changes, why, and what a reviewer should look at first.\n\n${title(p)}`;

/** Only points at the pull request: the question is yours to write. */
export const ask = (p: SessionPullRequestRef) => `About ${describe(p)}:\n\n${title(p)}`;

/** Everything that fails, so one message covers them. */
export const fixChecks = (p: SessionPullRequestRef, failing: string[]) =>
  `These checks fail on ${describe(p)}. Find out why and fix them:\n\n${untrusted("failing_checks", failing.map((n) => `- ${n}`).join("\n"))}`;
