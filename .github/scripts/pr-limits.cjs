// Two rules for pull requests from authors who are not vouched (`vouch:unvouched`, set by pr-vouch.yml), loaded by
// .github/workflows/pr-limits.yml from the default branch. It reads and writes through the API and never runs pull
// request code. Adapted from t3code's pr-limits (MIT).
//
//  - Open limit: a new pull request is closed when its author already has OPEN_LIMIT or more older ones open.
//  - Conflict window: a pull request that conflicts with its base is asked once to rebase (label `needs rebase`), and
//    closed when it still conflicts after 7 days without any activity.
//
// Collaborators with write access, bots, people in VOUCHED.td and anything labeled `keep open` are never touched.
// Nothing is written unless the workflow passes dryRun: false (repository variable NOOK_PR_LIMITS_ENFORCE=true).
// `decide` is pure and tested in pr-limits.test.cjs.

const fs = require("node:fs");

const HOUR_MS = 60 * 60 * 1000;
const OPEN_LIMIT = 3;
const CONFLICT_IDLE_MS = 7 * 24 * HOUR_MS;
// A first run meets the whole backlog; these keep one run from flooding watchers or the token's write limits.
const MAX_REQUESTS_PER_RUN = 50;
const MAX_CLOSES_PER_RUN = 25;
const WRITE_PAUSE_MS = 1_000;
// GitHub computes mergeability lazily: asking starts it, and it takes a couple of minutes for every open PR.
const MERGEABLE_WAIT_MS = 150_000;
const READ_ATTEMPTS = 4;
const READ_RETRY_MS = 5_000;

const REBASE_LABEL = "needs rebase";
const KEEP_OPEN_LABEL = "keep open";
const UNVOUCHED_LABEL = "vouch:unvouched";
const WRITE_PERMISSIONS = new Set(["admin", "maintain", "write"]);
const VOUCHED_PATH = ".github/VOUCHED.td";

const SWEEP_QUERY = `
  query ($owner: String!, $repo: String!, $labels: [String!], $cursor: String) {
    repository(owner: $owner, name: $repo) {
      pullRequests(states: OPEN, labels: $labels, first: 50, after: $cursor) {
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

const RECHECK_QUERY = `
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

const AUTHOR_OPEN_PRS_QUERY = `
  query ($q: String!) {
    search(query: $q, type: ISSUE, first: 50) {
      nodes { ... on PullRequest { number } }
    }
  }`;

const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Only reads are retried: repeating a read is safe, repeating a comment is not.
async function read(github, query, variables) {
  for (let attempt = 1; ; attempt += 1) {
    try {
      return await github.graphql(query, variables);
    } catch (error) {
      const transient = typeof error.status === "number" && error.status >= 500;
      if (attempt === READ_ATTEMPTS || !transient) throw error;
      await pause(attempt * READ_RETRY_MS);
    }
  }
}

// VOUCHED.td: `github:login` per line, `#` comments, `-github:login reason` to denounce (not vouched).
function vouchedLogins(text) {
  const logins = new Set();
  for (const raw of text.split("\n")) {
    const entry = raw.trim().split(/\s+/)[0];
    if (entry.startsWith("github:")) logins.add(entry.slice("github:".length).toLowerCase());
  }
  return logins;
}

// The whole policy of the conflict window. Activity is anything that moves the PR's updatedAt (a push, a comment, a
// review, a label), which the author cannot set, so nothing here trusts the author.
function decide(pr, vouched, now) {
  const labels = new Set(pr.labels.nodes.map((label) => label.name));
  if (labels.has(KEEP_OPEN_LABEL) || pr.isDraft) return labels.has(REBASE_LABEL) ? "clear-rebase" : "skip";
  const subject = labels.has(UNVOUCHED_LABEL) && !vouched.has((pr.author?.login ?? "").toLowerCase());
  if (labels.has(REBASE_LABEL)) {
    if (!subject || pr.mergeable === "MERGEABLE") return "clear-rebase";
    // Activity restarts the seven days and keeps the label, so a PR is asked to rebase once.
    const idle = now - Date.parse(pr.updatedAt) >= CONFLICT_IDLE_MS;
    return idle && pr.mergeable === "CONFLICTING" ? "close-conflict" : "skip";
  }
  return subject && pr.mergeable === "CONFLICTING" ? "request-rebase" : "skip";
}

function guideLink(context, anchor) {
  return `https://github.com/${context.repo.owner}/${context.repo.repo}/blob/HEAD/CONTRIBUTING.md#${anchor}`;
}

async function removeLabel(github, context, number, name) {
  try {
    await github.rest.issues.removeLabel({ ...context.repo, issue_number: number, name });
  } catch (error) {
    if (error.status !== 404) throw error;
  }
}

async function closeWithComment(github, context, number, body) {
  await github.rest.issues.createComment({ ...context.repo, issue_number: number, body });
  await github.rest.pulls.update({ ...context.repo, pull_number: number, state: "closed" });
}

async function sweep({ github, context, core, dryRun }) {
  const vouched = vouchedLogins(fs.readFileSync(VOUCHED_PATH, "utf8"));
  const repo = { owner: context.repo.owner, repo: context.repo.repo };
  const list = async () => {
    const prs = [];
    for (let cursor = null; ;) {
      const page = (await read(github, SWEEP_QUERY, { ...repo, cursor, labels: [UNVOUCHED_LABEL, REBASE_LABEL] }))
        .repository.pullRequests;
      prs.push(...page.nodes);
      if (!page.pageInfo.hasNextPage) return prs;
      cursor = page.pageInfo.endCursor;
    }
  };
  let prs = await list();
  if (prs.some((pr) => pr.mergeable === "UNKNOWN")) {
    await pause(MERGEABLE_WAIT_MS);
    prs = await list();
  }

  const now = Date.now();
  const count = {};
  for (const pr of prs) {
    const { number } = pr;
    let action = decide(pr, vouched, now);
    if (action === "skip") continue;
    if (action === "request-rebase" && (count[action] ?? 0) >= MAX_REQUESTS_PER_RUN) continue;
    if (action === "close-conflict") {
      if ((count[action] ?? 0) >= MAX_CLOSES_PER_RUN) continue;
      // The list is minutes old by now, and a merge into the base can resolve a conflict without touching the PR.
      const fresh = (await read(github, RECHECK_QUERY, { ...repo, number })).repository.pullRequest;
      if (fresh.state !== "OPEN") continue;
      action = decide({ ...pr, ...fresh }, vouched, now);
      if (action !== "close-conflict") continue;
    }

    count[action] = (count[action] ?? 0) + 1;
    core.info(`#${number} ${action}${dryRun ? " (dry run)" : ""}`);
    if (dryRun) continue;

    if (action === "request-rebase") {
      // The request goes first: a label without it would start a clock nobody was told about.
      await github.rest.issues.createComment({
        ...context.repo,
        issue_number: number,
        body: [
          `This pull request conflicts with \`${pr.baseRefName}\`. Merge \`${pr.baseRefName}\` into it or rebase it. If it still conflicts after 7 days without any activity, it is closed automatically.`,
          "",
          `See [Pull Request Guidelines](${guideLink(context, "pull-request-guidelines")}).`,
        ].join("\n"),
      });
      await github.rest.issues.addLabels({ ...context.repo, issue_number: number, labels: [REBASE_LABEL] });
    } else if (action === "clear-rebase") {
      await removeLabel(github, context, number, REBASE_LABEL);
    } else {
      await closeWithComment(
        github,
        context,
        number,
        [
          `Closing: this pull request still conflicts with \`${pr.baseRefName}\` and has had no activity for 7 days since the rebase request.`,
          "",
          "To continue, update the branch and reopen it, or open a new pull request that links this one.",
        ].join("\n"),
      );
      // Without this, a maintainer's reopen would be closed again by the next run.
      await removeLabel(github, context, number, REBASE_LABEL);
    }
    await pause(WRITE_PAUSE_MS);
  }
  const summary = Object.entries(count).map(([action, n]) => `${n} ${action}`);
  core.info(`${dryRun ? "Dry run. " : ""}${prs.length} pull requests read: ${summary.join(", ") || "nothing to do"}.`);
  return count;
}

async function enforceOpenLimit({ github, context, core, dryRun }) {
  const pr = context.payload.pull_request;
  const author = pr.user.login;
  // Trust is decided here rather than from the vouch label, which may not be set yet when a pull request opens.
  // Every read throws on failure, and a throw closes nothing.
  if (pr.user.type === "Bot") return;
  if (vouchedLogins(fs.readFileSync(VOUCHED_PATH, "utf8")).has(author.toLowerCase())) return;
  const { data: access } = await github.rest.repos.getCollaboratorPermissionLevel({ ...context.repo, username: author });
  if (WRITE_PERMISSIONS.has(access.permission)) return;
  if (pr.labels.some((label) => label.name === KEEP_OPEN_LABEL)) return;
  // Someone else reopening a pull request is a maintainer overriding the limit.
  const reopened = context.payload.action === "reopened";
  if (reopened && context.payload.sender.login.toLowerCase() !== author.toLowerCase()) return;

  const q = `repo:${context.repo.owner}/${context.repo.repo} is:pr is:open author:${author} sort:created-asc`;
  const { search } = await read(github, AUTHOR_OPEN_PRS_QUERY, { q });
  // Only older pull requests count, so two opened together cannot close each other.
  const others = search.nodes.filter(
    (node) => node.number && (reopened ? node.number !== pr.number : node.number < pr.number),
  ).length;
  if (others < OPEN_LIMIT) {
    core.info(`#${pr.number}: ${author} has ${others} other open pull requests.`);
    return;
  }
  if (dryRun) {
    core.notice(`Dry run. #${pr.number} would close: ${author} has ${others} other open pull requests.`);
    return;
  }
  await closeWithComment(
    github,
    context,
    pr.number,
    [
      `Thanks for the contribution! Closing for now: you already have ${others} open pull requests here, and new contributors can have ${OPEN_LIMIT} open at a time so each one gets a proper review.`,
      "",
      `Reopen this one once one of the others is merged or closed. See [Pull Request Guidelines](${guideLink(context, "pull-request-guidelines")}).`,
    ].join("\n"),
  );
  core.info(`#${pr.number}: closed, ${author} has ${others} other open pull requests.`);
}

module.exports = { decide, vouchedLogins, enforceOpenLimit, sweep, OPEN_LIMIT };
