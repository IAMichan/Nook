const test = require("node:test");
const assert = require("node:assert/strict");
const welcome = require("./welcome.cjs");

const REPO = "https://github.com/IAMichan/Nook";

test("isFirstPullRequest: only first-time contributors who are not bots", () => {
  assert.equal(welcome.isFirstPullRequest({ author_association: "FIRST_TIME_CONTRIBUTOR", user: { type: "User" } }), true);
  assert.equal(welcome.isFirstPullRequest({ author_association: "FIRST_TIMER", user: { type: "User" } }), true);
  assert.equal(welcome.isFirstPullRequest({ author_association: "CONTRIBUTOR", user: { type: "User" } }), false);
  assert.equal(welcome.isFirstPullRequest({ author_association: "OWNER", user: { type: "User" } }), false);
  assert.equal(welcome.isFirstPullRequest({ author_association: "FIRST_TIMER", user: { type: "Bot" } }), false);
});

test("isFirstIssue: counts issues, not pull requests, and skips maintainers", () => {
  const issue = { number: 5, author_association: "NONE", user: { type: "User" } };
  assert.equal(welcome.isFirstIssue(issue, [{ number: 5 }]), true);
  assert.equal(welcome.isFirstIssue(issue, [{ number: 5 }, { number: 2, pull_request: {} }]), true);
  assert.equal(welcome.isFirstIssue(issue, [{ number: 5 }, { number: 2 }]), false);
  assert.equal(welcome.isFirstIssue({ ...issue, author_association: "OWNER" }, [{ number: 5 }]), false);
  assert.equal(welcome.isFirstIssue({ ...issue, user: { type: "Bot" } }, [{ number: 5 }]), false);
});

test("messages start with the marker, mention the author and link absolutely", () => {
  for (const message of [welcome.pullRequestMessage("ada", REPO), welcome.issueMessage("ada", REPO)]) {
    assert.ok(message.startsWith(welcome.MARKER));
    assert.match(message, /@ada/);
    assert.match(message, /https:\/\/github\.com\/IAMichan\/Nook\/blob\/HEAD\/CONTRIBUTING\.md/);
    // pr-vouch.yml reruns on comments with this command; a bot comment must never contain it.
    assert.doesNotMatch(message, /\/recheck-vouch/);
  }
});

test("run: welcomes once and skips when the marker is already there", async () => {
  const created = [];
  const github = {
    rest: { issues: { listComments: "listComments", listForRepo: "listForRepo", createComment: async (args) => created.push(args) } },
    paginate: async (method) => (method === "listComments" ? existing : []),
  };
  const core = { info() {} };
  const context = {
    repo: { owner: "IAMichan", repo: "Nook" },
    payload: {
      repository: { html_url: REPO },
      pull_request: { number: 9, author_association: "FIRST_TIME_CONTRIBUTOR", user: { login: "ada", type: "User" } },
    },
  };
  let existing = [];
  await welcome.run({ github, context, core });
  assert.equal(created.length, 1);
  assert.equal(created[0].issue_number, 9);

  existing = [{ body: `${welcome.MARKER}\nhello` }];
  await welcome.run({ github, context, core });
  assert.equal(created.length, 1);
});
