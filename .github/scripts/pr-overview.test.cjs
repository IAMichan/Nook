const test = require("node:test");
const assert = require("node:assert/strict");
const { MARKER, summarize, render, nextSteps, findPullNumber } = require("./pr-overview.cjs");

test("summarize: basic draft PR with no runs", () => {
  const pr = {
    number: 10,
    draft: true,
    mergeable_state: "clean",
    labels: [{ name: "size:S" }, { name: "vouch:trusted" }, { name: "area: macos" }],
    user: { login: "alice" },
  };
  const checkRuns = [];
  const reviews = [];

  const summary = summarize({ pr, checkRuns, reviews });
  assert.equal(summary.number, 10);
  assert.equal(summary.draft, true);
  assert.equal(summary.size, "S");
  assert.equal(summary.vouch, "trusted");
  assert.deepEqual(summary.areaLabels, ["macos"]);
  assert.equal(summary.gate.state, "missing");
  assert.equal(summary.approved, 0);

  const rendered = render(summary);
  assert.ok(rendered.startsWith(MARKER));
  assert.ok(rendered.includes("Not started: CI does not run on drafts."));
  assert.ok(rendered.includes("Mark the pull request **ready for review**"));
});

test("summarize: running CI with partial failures", () => {
  const pr = {
    number: 11,
    draft: false,
    mergeable_state: "clean",
    labels: [{ name: "size:M" }, { name: "vouch:unvouched" }],
    user: { login: "bob" },
  };
  const checkRuns = [
    { name: "Check", status: "in_progress", conclusion: null },
    { name: "macos / Build", status: "completed", conclusion: "failure", html_url: "https://ci/fail" },
    { name: "relay / Deploy", status: "in_progress", conclusion: null },
  ];
  const reviews = [];

  const summary = summarize({ pr, checkRuns, reviews });
  assert.equal(summary.draft, false);
  assert.equal(summary.ciRunning, true);
  assert.equal(summary.failedJobs.length, 1);
  assert.equal(summary.failedJobs[0].name, "macos / Build");

  const rendered = render(summary);
  assert.ok(rendered.includes("Running. Already failing: [macos / Build](https://ci/fail)."));
  assert.ok(rendered.includes("Fix the failing CI job: [macos / Build](https://ci/fail)."));
});

test("summarize: all green, 1 approval -> ready to merge", () => {
  const pr = {
    number: 12,
    draft: false,
    mergeable_state: "clean",
    labels: [{ name: "size:XS" }, { name: "vouch:trusted" }],
    user: { login: "alice" },
  };
  const checkRuns = [
    { name: "Check", status: "completed", conclusion: "success" },
    { name: "Description follows template", status: "completed", conclusion: "success" },
    { name: "macos / Build", status: "completed", conclusion: "success" },
  ];
  const reviews = [{ user: { login: "reviewer1" }, state: "APPROVED" }];

  const summary = summarize({ pr, checkRuns, reviews });
  assert.equal(summary.gate.state, "passed");
  assert.equal(summary.approved, 1);

  const rendered = render(summary);
  assert.ok(rendered.includes("Passed (macos)."));
  assert.ok(rendered.includes("**Ready to merge.**"));
});

test("summarize: review handling (author excluded, changes requested overrides approved)", () => {
  const pr = {
    number: 13,
    draft: false,
    labels: [],
    user: { login: "author1" },
  };
  const checkRuns = [];
  const reviews = [
    { user: { login: "author1" }, state: "APPROVED" }, // author self-approval ignored
    { user: { login: "rev1" }, state: "APPROVED" },
    { user: { login: "rev2" }, state: "APPROVED" },
    { user: { login: "rev2" }, state: "CHANGES_REQUESTED" }, // rev2 changed mind
  ];

  const summary = summarize({ pr, checkRuns, reviews });
  assert.equal(summary.approved, 1);
  assert.deepEqual(summary.changesRequested, ["rev2"]);

  const steps = nextSteps(summary);
  assert.ok(steps.some((s) => s.includes("Address the changes requested by @rev2")));
});

test("findPullNumber: finds from pull_request payload, workflow_run, or head_sha", async () => {
  // from pull_request
  const num1 = await findPullNumber({
    context: { payload: { pull_request: { number: 42 } } },
  });
  assert.equal(num1, 42);

  // from workflow_run.pull_requests
  const num2 = await findPullNumber({
    context: { payload: { workflow_run: { pull_requests: [{ number: 99 }] } } },
  });
  assert.equal(num2, 99);

  // from workflow_run matching head_sha via paginate
  const num3 = await findPullNumber({
    github: {
      paginate: async () => [{ head: { sha: "abc123" }, number: 77 }],
      rest: { pulls: { list: () => {} } },
    },
    context: {
      repo: { owner: "owner", repo: "repo" },
      payload: { workflow_run: { pull_requests: [], head_sha: "abc123" } },
    },
  });
  assert.equal(num3, 77);
});

test("run: keeps the oldest overview and deletes duplicates from parallel runs", async () => {
  const { run, MARKER } = require("./pr-overview.cjs");
  const deleted = [];
  const updated = [];
  const comments = [
    { id: 30, user: { type: "Bot" }, body: `${MARKER}\nnewer` },
    { id: 10, user: { type: "Bot" }, body: `${MARKER}\nolder` },
    { id: 20, user: { type: "User" }, body: `${MARKER}\nquoted by a person` },
  ];
  const github = {
    rest: {
      pulls: {
        get: async () => ({
          data: { number: 4, state: "open", draft: false, user: { login: "a", type: "User" }, labels: [], head: { sha: "s" }, base: { repo: { html_url: "https://github.com/IAMichan/Nook" } } },
        }),
        listReviews: "listReviews",
      },
      checks: { listForRef: "listForRef" },
      issues: {
        listComments: "listComments",
        updateComment: async (args) => updated.push(args.comment_id),
        createComment: async () => assert.fail("must not create a second overview"),
        deleteComment: async (args) => deleted.push(args.comment_id),
      },
    },
    paginate: async (method) => (method === "listComments" ? comments : []),
  };
  const context = { repo: { owner: "IAMichan", repo: "Nook" }, payload: { pull_request: { number: 4 } } };
  await run({ github, context, core: { info() {} } });
  assert.deepEqual(updated, [10]);
  assert.deepEqual(deleted, [30]);
});

test("countTestDelta: counts declarations per language, ignores other files", () => {
  const { countTestDelta } = require("./pr-overview.cjs");
  const files = [
    {
      filename: "apps/macos/Tests/NookTests/RunStoreTests.swift",
      patch: "@@ -1,3 +1,6 @@\n+    func testSavesOnce() {\n+    @MainActor func testMainActor() async {\n-    func testOld() {\n+    @Test func modern() {\n     func helper() {",
    },
    { filename: "apps/tauri/src/app.test.ts", patch: "@@ -0,0 +1,2 @@\n+it(\"works\", () => {});\n+test.each([1])(\"x\", () => {});" },
    { filename: "apps/chatd/store_test.go", patch: "@@ -1 +1 @@\n-func TestOpen(t *testing.T) {" },
    { filename: "apps/tauri/src-tauri/src/lib.rs", patch: "@@ -1 +1,2 @@\n+    #[test]\n+    #[tokio::test]" },
    // Not a test file: a function named like a test does not count.
    { filename: "apps/macos/Core/Thing.swift", patch: "@@ -1 +1 @@\n+    func testable() {" },
  ];
  assert.deepEqual(countTestDelta(files), { added: 7, removed: 2, incomplete: false });
  assert.deepEqual(countTestDelta([{ filename: "Tests/Big.swift", changes: 9000 }]), { added: 0, removed: 0, incomplete: true });
});

test("render: tests and preview rows", () => {
  const pr = { number: 20, draft: false, mergeable_state: "clean", labels: [], user: { login: "a" } };
  const checkRuns = [
    {
      name: "Build preview app",
      status: "completed",
      conclusion: "success",
      html_url: "https://github.com/o/r/actions/runs/5/job/9",
    },
  ];
  const files = [{ filename: "x.test.js", patch: "@@\n-it(\"a\", f);\n-it(\"b\", f);\n+it(\"c\", f);" }];
  const summary = summarize({ pr, checkRuns, reviews: [], files });
  // The preview job is not a CI job.
  assert.equal(summary.failedJobs.length, 0);
  assert.equal(summary.ciRunning, false);
  const rendered = render(summary);
  assert.ok(rendered.includes("| Tests | +1 / −2 test cases: removes more tests than it adds. |"));
  assert.ok(rendered.includes("[Download the app](https://github.com/o/r/actions/runs/5)"));
});
