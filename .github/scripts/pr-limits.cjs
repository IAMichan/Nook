// Pull request limits for contributors who are not vouched yet. Loaded by .github/workflows/pr-limits.yml from the
// default branch; it only talks to the GitHub API and never checks out or runs code from a pull request.
//
// Rule 1, open limit (enforceOpenLimit, on opened/reopened):
//   an unvouched author may keep OPEN_LIMIT pull requests open. A pull request that would go past that is closed with
//   a friendly comment.
// Rule 2, conflict window (sweep, daily or by hand):
//   an unvouched pull request that conflicts with its base gets one comment and the `needs rebase` label. If it still
//   conflicts after a full week without activity, it is closed. The label goes away as soon as it no longer applies.
//
// Exempt from both: people with write access, bots, logins listed in .github/VOUCHED.td, drafts (rule 2 only) and
// anything labeled `keep open`. With dryRun the script only logs; the workflow turns writes on through the repository
// variable NOOK_PR_LIMITS_ENFORCE. The rule 2 policy lives in the pure function `decide` (see pr-limits.test.cjs).

const { readFileSync } = require("node:fs");

const OPEN_LIMIT = 3;

const DAY_MS = 24 * 60 * 60 * 1000;
const STALE_CONFLICT_MS = 7 * DAY_MS;

const LABEL = Object.freeze({
  rebase: "needs rebase",
  keepOpen: "keep open",
  unvouched: "vouch:unvouched",
});

const ACTION = Object.freeze({
  none: "skip",
  ask: "request-rebase",
  unlabel: "clear-rebase",
  close: "close-conflict",
});

// Caps for one sweep, so the first run over an old backlog does not bury watchers in notifications or hit the
// token's secondary rate limits.
const RUN_CAP = Object.freeze({ [ACTION.ask]: 50, [ACTION.close]: 25 });

const SPACING_MS = 1000; // between write batches
const MERGEABILITY_SETTLE_MS = 150 * 1000; // GitHub fills in `mergeable` lazily after it is first asked for
const RETRY_LIMIT = 4;
const RETRY_STEP_MS = 5000;

const VOUCH_FILE = ".github/VOUCHED.td";
const WRITERS = ["admin", "maintain", "write"];

const sleep = (ms) => new Promise((done) => setTimeout(done, ms));

// ---------------------------------------------------------------------------------------------------------------------
// Pure helpers

/**
 * Parses VOUCHED.td into a set of lowercase logins. A line vouches for someone when its first word is
 * `github:<login>`; comment lines (`#`) and denounced entries (`-github:<login> ...`) are ignored.
 */
function vouchedLogins(source) {
  const result = new Set();
  const prefix = "github:";
  for (const line of source.split(/\r?\n/)) {
    const [first = ""] = line.trim().split(/\s+/);
    if (!first.startsWith(prefix)) continue;
    const login = first.slice(prefix.length).toLowerCase();
    if (login) result.add(login);
  }
  return result;
}

/**
 * Decides what the conflict sweep should do with one open pull request.
 *
 * `pr` has the GraphQL shape { isDraft, mergeable, updatedAt, author: { login }, labels: { nodes: [{ name }] } }.
 * Returns one of "skip", "request-rebase", "clear-rebase" or "close-conflict".
 *
 * The idle clock uses `updatedAt`, which moves on any push, comment, review or label change, so every bit of
 * activity buys another week while the single rebase request stays in place.
 */
function decide(pr, vouched, now) {
  const names = new Set((pr.labels?.nodes ?? []).map((node) => node.name));
  const labeled = names.has(LABEL.rebase);

  // Out of scope: kept open on purpose, still a draft, or the author is trusted after all.
  const login = (pr.author?.login ?? "").toLowerCase();
  const inScope =
    !names.has(LABEL.keepOpen) && !pr.isDraft && names.has(LABEL.unvouched) && !vouched.has(login);
  if (!inScope) return labeled ? ACTION.unlabel : ACTION.none;

  if (pr.mergeable === "MERGEABLE") return labeled ? ACTION.unlabel : ACTION.none;
  if (pr.mergeable !== "CONFLICTING") return ACTION.none; // UNKNOWN: try again on the next run

  if (!labeled) return ACTION.ask;
  const quietFor = now - Date.parse(pr.updatedAt);
  return quietFor >= STALE_CONFLICT_MS ? ACTION.close : ACTION.none;
}

// ---------------------------------------------------------------------------------------------------------------------
// GitHub access

const OPEN_PULLS = `
  query ($owner: String!, $repo: String!, $labels: [String!], $after: String) {
    repository(owner: $owner, name: $repo) {
      pullRequests(states: OPEN, labels: $labels, first: 50, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          number
          isDraft
          mergeable
          baseRefName
          updatedAt
          author { login }
          labels(first: 100) { nodes { name } }
        }
      }
    }
  }`;

const ONE_PULL = `
  query ($owner: String!, $repo: String!, $number: Int!) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $number) {
        state
        isDraft
        mergeable
        updatedAt
        labels(first: 100) { nodes { name } }
      }
    }
  }`;

const OPEN_BY_AUTHOR = `
  query ($q: String!) {
    search(query: $q, type: ISSUE, first: 50) {
      nodes { ... on PullRequest { number } }
    }
  }`;

/** GraphQL read with a short backoff on server errors. Writes are never retried, so nothing is posted twice. */
async function query(github, text, variables) {
  let attempt = 0;
  while (true) {
    attempt += 1;
    try {
      return await github.graphql(text, variables);
    } catch (error) {
      const serverSide = Number.isInteger(error?.status) && error.status >= 500;
      if (!serverSide || attempt >= RETRY_LIMIT) throw error;
      await sleep(RETRY_STEP_MS * attempt);
    }
  }
}

async function listCandidates(github, repo) {
  const found = [];
  let after = null;
  do {
    const data = await query(github, OPEN_PULLS, { ...repo, after, labels: [LABEL.unvouched, LABEL.rebase] });
    const { nodes, pageInfo } = data.repository.pullRequests;
    found.push(...nodes);
    after = pageInfo.hasNextPage ? pageInfo.endCursor : null;
  } while (after);
  return found;
}

function readVouched() {
  return vouchedLogins(readFileSync(VOUCH_FILE, "utf8"));
}

function guidelinesUrl({ repo }) {
  return `https://github.com/${repo.owner}/${repo.repo}/blob/HEAD/CONTRIBUTING.md#pull-request-guidelines`;
}

function comment(github, context, number, lines) {
  return github.rest.issues.createComment({ ...context.repo, issue_number: number, body: lines.join("\n") });
}

async function dropRebaseLabel(github, context, number) {
  try {
    await github.rest.issues.removeLabel({ ...context.repo, issue_number: number, name: LABEL.rebase });
  } catch (error) {
    if (error?.status !== 404) throw error; // already gone is fine
  }
}

async function closePull(github, context, number) {
  await github.rest.pulls.update({ ...context.repo, pull_number: number, state: "closed" });
}

// ---------------------------------------------------------------------------------------------------------------------
// Rule 2: conflict window

async function apply(action, pr, { github, context }) {
  const base = pr.baseRefName;
  switch (action) {
    case ACTION.ask:
      // Comment before labeling: the label starts the clock, and the author should hear about it first.
      await comment(github, context, pr.number, [
        `This pull request has merge conflicts with \`${base}\`. Please rebase it or merge \`${base}\` into it.`,
        "If the conflicts are still there after 7 days with no activity, the pull request will be closed automatically.",
        "",
        `More in the [Pull Request Guidelines](${guidelinesUrl(context)}).`,
      ]);
      await github.rest.issues.addLabels({ ...context.repo, issue_number: pr.number, labels: [LABEL.rebase] });
      return;
    case ACTION.unlabel:
      await dropRebaseLabel(github, context, pr.number);
      return;
    case ACTION.close:
      await comment(github, context, pr.number, [
        `Closing this pull request: it has conflicted with \`${base}\` for 7 days without activity after the rebase request.`,
        "",
        "Feel free to update the branch and reopen it, or open a new pull request that refers to this one.",
      ]);
      await closePull(github, context, pr.number);
      // Clear the label too, otherwise the next sweep would close it again right after a maintainer reopens it.
      await dropRebaseLabel(github, context, pr.number);
      return;
    default:
      throw new Error(`Unknown action ${action}`);
  }
}

async function sweep({ github, context, core, dryRun }) {
  const vouched = readVouched();
  const repo = { owner: context.repo.owner, repo: context.repo.repo };

  let pulls = await listCandidates(github, repo);
  if (pulls.some((pull) => pull.mergeable === "UNKNOWN")) {
    // The first listing kicked off the mergeability check; give GitHub time and read again.
    await sleep(MERGEABILITY_SETTLE_MS);
    pulls = await listCandidates(github, repo);
  }

  const now = Date.now();
  const tally = {};
  const used = (action) => tally[action] ?? 0;
  const capped = (action) => action in RUN_CAP && used(action) >= RUN_CAP[action];

  for (const pull of pulls) {
    let action = decide(pull, vouched, now);
    if (action === ACTION.none || capped(action)) continue;

    if (action === ACTION.close) {
      // Look again right before closing: the listing may be minutes old and a change to the base can have
      // resolved the conflict without touching the pull request itself.
      const latest = (await query(github, ONE_PULL, { ...repo, number: pull.number })).repository.pullRequest;
      if (latest.state !== "OPEN") continue;
      action = decide({ ...pull, ...latest }, vouched, now);
      if (action !== ACTION.close) continue;
    }

    tally[action] = used(action) + 1;
    core.info(`#${pull.number} ${action}${dryRun ? " (dry run)" : ""}`);
    if (dryRun) continue;

    await apply(action, pull, { github, context });
    await sleep(SPACING_MS);
  }

  const parts = Object.entries(tally).map(([action, n]) => `${n} ${action}`);
  const outcome = parts.length ? parts.join(", ") : "nothing to do";
  core.info(`${dryRun ? "Dry run. " : ""}${pulls.length} pull requests read: ${outcome}.`);
  return tally;
}

// ---------------------------------------------------------------------------------------------------------------------
// Rule 1: open limit

/** True when the author of this event is outside the open limit. Any failed read throws, which closes nothing. */
async function isExempt({ github, context }, pull) {
  const login = pull.user.login;
  if (pull.user.type === "Bot") return true;
  // The vouch label may not be set yet on a brand-new pull request, so trust is checked directly here.
  if (readVouched().has(login.toLowerCase())) return true;
  const { data } = await github.rest.repos.getCollaboratorPermissionLevel({ ...context.repo, username: login });
  if (WRITERS.includes(data.permission)) return true;
  if ((pull.labels ?? []).some((label) => label.name === LABEL.keepOpen)) return true;
  // A reopen by someone other than the author is a maintainer deliberately letting it through.
  const reopenedBySomeoneElse =
    context.payload.action === "reopened" && context.payload.sender.login.toLowerCase() !== login.toLowerCase();
  return reopenedBySomeoneElse;
}

async function enforceOpenLimit({ github, context, core, dryRun }) {
  const pull = context.payload.pull_request;
  if (await isExempt({ github, context }, pull)) return;

  const login = pull.user.login;
  const reopened = context.payload.action === "reopened";
  const q = `repo:${context.repo.owner}/${context.repo.repo} is:pr is:open author:${login} sort:created-asc`;
  const { search } = await query(github, OPEN_BY_AUTHOR, { q });

  // A new pull request only counts the ones opened before it, so two opened at once cannot close each other.
  // A reopened one counts every other open pull request.
  const counts = (number) => (reopened ? number !== pull.number : number < pull.number);
  const ahead = search.nodes.filter((node) => node.number && counts(node.number)).length;

  if (ahead < OPEN_LIMIT) {
    core.info(`#${pull.number}: ${login} has ${ahead} other open pull requests.`);
    return;
  }
  if (dryRun) {
    core.notice(`Dry run. #${pull.number} would close: ${login} has ${ahead} other open pull requests.`);
    return;
  }

  await comment(github, context, pull.number, [
    `Thank you for opening this! You already have ${ahead} open pull requests in this repository, and until you are vouched for, the limit is ${OPEN_LIMIT} at a time so every one of them gets a careful review. Closing this one for now.`,
    "",
    `Once one of the others is merged or closed, reopen this one. More in the [Pull Request Guidelines](${guidelinesUrl(context)}).`,
  ]);
  await closePull(github, context, pull.number);
  core.info(`#${pull.number}: closed, ${login} has ${ahead} other open pull requests.`);
}

module.exports = { decide, vouchedLogins, enforceOpenLimit, sweep, OPEN_LIMIT };
