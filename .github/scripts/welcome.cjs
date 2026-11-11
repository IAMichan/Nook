// Welcomes someone on their first issue or first pull request in this repository, so they know what happens next
// without a maintainer typing it every time. Loaded by .github/workflows/welcome.yml from the default branch; it only
// calls the GitHub API.
//
// `isFirstPullRequest`, `isFirstIssue` and the messages are pure (tested in welcome.test.cjs); `run` does the calls.

const MARKER = "<!-- nook-welcome -->";
const MAINTAINER_ROLES = new Set(["OWNER", "MEMBER", "COLLABORATOR"]);

// GitHub marks someone who never had a pull request merged here as FIRST_TIME_CONTRIBUTOR, and someone new to GitHub
// as FIRST_TIMER.
function isFirstPullRequest(pr) {
  if (pr.user?.type === "Bot") return false;
  return ["FIRST_TIME_CONTRIBUTOR", "FIRST_TIMER"].includes(pr.author_association);
}

// `issuesByAuthor` is every issue and pull request the author opened here (the API lists both); this one included.
function isFirstIssue(issue, issuesByAuthor) {
  if (issue.user?.type === "Bot" || MAINTAINER_ROLES.has(issue.author_association)) return false;
  return issuesByAuthor.filter((item) => !item.pull_request).length <= 1;
}

function pullRequestMessage(login, repoUrl) {
  return [
    MARKER,
    `Thanks for your first pull request to Nook, @${login}! Here is what happens next:`,
    "",
    "- **The overview comment** on this pull request keeps itself up to date: what CI says, whether the description is complete, and what is still needed before it can merge.",
    "- **CI** builds and tests only what your change touches. The required check is called `Check`; open it to see which job failed and why.",
    "- **Labels** for size, area and author are added automatically. They help maintainers plan reviews; they say nothing about the quality of your work.",
    "- **A maintainer reviews** once CI is green. Questions from the review or from CodeRabbit are normal, and we are happy to help you get it over the line.",
    "",
    `Before you push again: keep the pull request to one problem, fill in every section of the template, and run \`./scripts/core-tests.sh\` locally. Everything else is in [CONTRIBUTING.md](${repoUrl}/blob/HEAD/CONTRIBUTING.md).`,
  ].join("\n");
}

function issueMessage(login, repoUrl) {
  return [
    MARKER,
    `Thanks for opening your first issue for Nook, @${login}! A maintainer will read it and label it.`,
    "",
    "- If we need more details, we add the `needs more info` label; the issue closes after 7 days without a reply, and a comment with the details reopens the conversation.",
    `- Ideas and feature requests are discussed in [Discussions → Ideas](${repoUrl}/discussions/categories/ideas), where others can vote on them.`,
    `- Want to fix it yourself? See [CONTRIBUTING.md](${repoUrl}/blob/HEAD/CONTRIBUTING.md); comment here first so nobody does the same work twice.`,
  ].join("\n");
}

async function run({ github, context, core }) {
  const repoUrl = context.payload.repository.html_url;
  const pr = context.payload.pull_request;
  const issue = context.payload.issue;
  let number;
  let body;
  if (pr) {
    if (!isFirstPullRequest(pr)) return core.info(`#${pr.number}: not a first pull request.`);
    number = pr.number;
    body = pullRequestMessage(pr.user.login, repoUrl);
  } else if (issue && !issue.pull_request) {
    const byAuthor = await github.paginate(github.rest.issues.listForRepo, {
      ...context.repo,
      creator: issue.user.login,
      state: "all",
      per_page: 100,
    });
    if (!isFirstIssue(issue, byAuthor)) return core.info(`#${issue.number}: not a first issue.`);
    number = issue.number;
    body = issueMessage(issue.user.login, repoUrl);
  } else {
    return core.info("Nothing to welcome.");
  }

  // A reopened or edited item must not be welcomed twice.
  const comments = await github.paginate(github.rest.issues.listComments, {
    ...context.repo,
    issue_number: number,
    per_page: 100,
  });
  if (comments.some((comment) => comment.body?.startsWith(MARKER))) return core.info(`#${number}: already welcomed.`);
  await github.rest.issues.createComment({ ...context.repo, issue_number: number, body });
  core.info(`#${number}: welcomed.`);
}

module.exports = { MARKER, isFirstPullRequest, isFirstIssue, pullRequestMessage, issueMessage, run };
