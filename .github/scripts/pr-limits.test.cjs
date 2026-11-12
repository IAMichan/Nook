// Run from the repository root (as ci.yml does), so .github/VOUCHED.td resolves.
const { describe, it } = require("node:test");
const assert = require("node:assert/strict");
const limits = require("./pr-limits.cjs");

const { decide, vouchedLogins, enforceOpenLimit, sweep, OPEN_LIMIT } = limits;

const DAY = 86_400_000;
const NOW = Date.parse("2026-11-12T12:00:00Z");
const NOBODY = new Set();
const STRANGER = "nook-test-stranger-without-vouch";

function pull(overrides = {}) {
  const { labels = ["vouch:unvouched"], mergeable = "CONFLICTING", quietDays = 0, login = STRANGER, draft = false } =
    overrides;
  return {
    number: 7,
    isDraft: draft,
    mergeable,
    baseRefName: "main",
    author: { login },
    updatedAt: new Date(NOW - quietDays * DAY).toISOString(),
    labels: { nodes: labels.map((name) => ({ name })) },
  };
}

describe("decide", () => {
  it("asks a conflicting unvouched pull request to rebase", () => {
    assert.equal(decide(pull(), NOBODY, NOW), "request-rebase");
  });

  it("leaves clean or not yet computed pull requests alone", () => {
    assert.equal(decide(pull({ mergeable: "MERGEABLE" }), NOBODY, NOW), "skip");
    assert.equal(decide(pull({ mergeable: "UNKNOWN" }), NOBODY, NOW), "skip");
  });

  it("waits a full week of inactivity after the request before closing", () => {
    const labels = ["vouch:unvouched", "needs rebase"];
    assert.equal(decide(pull({ labels, quietDays: 0 }), NOBODY, NOW), "skip");
    assert.equal(decide(pull({ labels, quietDays: 6.9 }), NOBODY, NOW), "skip");
    assert.equal(decide(pull({ labels, quietDays: 7 }), NOBODY, NOW), "close-conflict");
    assert.equal(decide(pull({ labels, quietDays: 40, mergeable: "UNKNOWN" }), NOBODY, NOW), "skip");
  });

  it("removes the label once the conflict is gone", () => {
    const labels = ["vouch:unvouched", "needs rebase"];
    assert.equal(decide(pull({ labels, quietDays: 40, mergeable: "MERGEABLE" }), NOBODY, NOW), "clear-rebase");
  });

  it("exempts trusted, vouched, kept-open and draft pull requests", () => {
    assert.equal(decide(pull({ labels: ["vouch:trusted"] }), NOBODY, NOW), "skip");
    assert.equal(decide(pull({ login: "Someone" }), new Set(["someone"]), NOW), "skip");
    assert.equal(decide(pull({ labels: ["vouch:unvouched", "keep open"] }), NOBODY, NOW), "skip");
    assert.equal(decide(pull({ draft: true }), NOBODY, NOW), "skip");
  });

  it("removes a leftover label from an exempt pull request instead of closing it", () => {
    const old = { quietDays: 40 };
    assert.equal(decide(pull({ ...old, labels: ["vouch:unvouched", "needs rebase", "keep open"] }), NOBODY, NOW), "clear-rebase");
    assert.equal(decide(pull({ ...old, labels: ["vouch:trusted", "needs rebase"] }), NOBODY, NOW), "clear-rebase");
    assert.equal(decide(pull({ ...old, labels: ["vouch:unvouched", "needs rebase"], draft: true }), NOBODY, NOW), "clear-rebase");
    assert.equal(
      decide(pull({ ...old, labels: ["vouch:unvouched", "needs rebase"], login: "Pal" }), new Set(["pal"]), NOW),
      "clear-rebase",
    );
  });
});

describe("vouchedLogins", () => {
  it("collects lowercase logins and ignores comments, blanks and denounced entries", () => {
    const parsed = vouchedLogins("# who we trust\ngithub:Ada\r\n-github:spammer reason here\n\n  github:linus   # note\n");
    assert.deepEqual([...parsed].sort(), ["ada", "linus"]);
  });

  it("returns an empty set for an empty file", () => {
    assert.equal(vouchedLogins("").size, 0);
  });
});

function recorder({ permission = "read", openNumbers = [], pullRequests = [], recheck = {} } = {}) {
  const writes = [];
  const logs = [];
  const github = {
    graphql: async (text, variables) => {
      if (text.includes("search(")) return { search: { nodes: openNumbers.map((number) => ({ number })) } };
      if (text.includes("pullRequest(number")) {
        return { repository: { pullRequest: { state: "OPEN", ...recheck[variables.number] } } };
      }
      return { repository: { pullRequests: { nodes: pullRequests, pageInfo: { hasNextPage: false, endCursor: null } } } };
    },
    rest: {
      repos: { getCollaboratorPermissionLevel: async () => ({ data: { permission } }) },
      issues: {
        createComment: async (args) => writes.push(["comment", args.issue_number]),
        addLabels: async (args) => writes.push(["label", args.issue_number]),
        removeLabel: async (args) => writes.push(["unlabel", args.issue_number]),
      },
      pulls: { update: async (args) => writes.push(["close", args.pull_number, args.state]) },
    },
  };
  const core = { info: (line) => logs.push(line), notice: (line) => logs.push(line) };
  return { github, core, writes, logs };
}

function openedEvent({ number = 10, login = STRANGER, type = "User", labels = [], action = "opened", sender = login } = {}) {
  return {
    repo: { owner: "owner", repo: "repo" },
    payload: { action, sender: { login: sender }, pull_request: { number, user: { login, type }, labels } },
  };
}

describe("enforceOpenLimit", () => {
  it("closes a pull request past the limit, counting only older ones", async () => {
    const older = Array.from({ length: OPEN_LIMIT }, (_, i) => i + 1);
    const run = recorder({ openNumbers: [...older, 10, 11] });
    await enforceOpenLimit({ ...run, context: openedEvent(), dryRun: false });
    assert.deepEqual(run.writes, [["comment", 10], ["close", 10, "closed"]]);
  });

  it("keeps a pull request open while the author is under the limit", async () => {
    const run = recorder({ openNumbers: [1, 2, 10, 11, 12] });
    await enforceOpenLimit({ ...run, context: openedEvent(), dryRun: false });
    assert.deepEqual(run.writes, []);
  });

  it("counts every other open pull request when the author reopens one", async () => {
    const run = recorder({ openNumbers: [10, 11, 12, 13] });
    await enforceOpenLimit({ ...run, context: openedEvent({ action: "reopened" }), dryRun: false });
    assert.deepEqual(run.writes, [["comment", 10], ["close", 10, "closed"]]);
  });

  it("only logs in a dry run", async () => {
    const run = recorder({ openNumbers: [1, 2, 3, 10] });
    await enforceOpenLimit({ ...run, context: openedEvent(), dryRun: true });
    assert.deepEqual(run.writes, []);
    assert.match(run.logs.join("\n"), /would close/);
  });

  it("exempts bots, writers, keep open and a reopen by someone else", async () => {
    const full = [1, 2, 3, 4, 10];
    const cases = [
      [{}, openedEvent({ type: "Bot" })],
      [{ permission: "write" }, openedEvent()],
      [{ permission: "maintain" }, openedEvent()],
      [{ permission: "admin" }, openedEvent()],
      [{}, openedEvent({ labels: [{ name: "keep open" }] })],
      [{}, openedEvent({ action: "reopened", sender: "a-maintainer" })],
    ];
    for (const [options, context] of cases) {
      const run = recorder({ ...options, openNumbers: full });
      await enforceOpenLimit({ ...run, context, dryRun: false });
      assert.deepEqual(run.writes, [], JSON.stringify(context.payload));
    }
  });
});

describe("sweep", () => {
  const context = { repo: { owner: "owner", repo: "repo" } };

  it("logs every planned action in a dry run and writes nothing", async () => {
    const pullRequests = [
      { ...pull(), number: 1, updatedAt: new Date().toISOString() },
      { ...pull({ labels: ["vouch:unvouched", "needs rebase"], quietDays: 30 }), number: 2, updatedAt: "2000-01-01T00:00:00Z" },
      { ...pull({ labels: ["vouch:trusted", "needs rebase"] }), number: 3 },
      { ...pull({ mergeable: "MERGEABLE" }), number: 4 },
    ];
    const run = recorder({ pullRequests, recheck: { 2: pullRequests[1] } });
    const tally = await sweep({ ...run, context, dryRun: true });
    assert.deepEqual(tally, { "request-rebase": 1, "close-conflict": 1, "clear-rebase": 1 });
    assert.deepEqual(run.writes, []);
  });

  it("does not close when a fresh read shows the conflict is resolved", async () => {
    const stale = { ...pull({ labels: ["vouch:unvouched", "needs rebase"] }), number: 5, updatedAt: "2000-01-01T00:00:00Z" };
    const run = recorder({ pullRequests: [stale], recheck: { 5: { mergeable: "MERGEABLE" } } });
    const tally = await sweep({ ...run, context, dryRun: true });
    assert.deepEqual(tally, {});
  });

  it("does not close a pull request that is no longer open", async () => {
    const stale = { ...pull({ labels: ["vouch:unvouched", "needs rebase"] }), number: 6, updatedAt: "2000-01-01T00:00:00Z" };
    const run = recorder({ pullRequests: [stale], recheck: { 6: { state: "CLOSED" } } });
    assert.deepEqual(await sweep({ ...run, context, dryRun: true }), {});
  });

  it("caps rebase requests and closes per run", async () => {
    const asks = Array.from({ length: 60 }, (_, i) => ({ ...pull(), number: 100 + i, updatedAt: new Date().toISOString() }));
    const closes = Array.from({ length: 30 }, (_, i) => ({
      ...pull({ labels: ["vouch:unvouched", "needs rebase"] }),
      number: 200 + i,
      updatedAt: "2000-01-01T00:00:00Z",
    }));
    const recheck = Object.fromEntries(closes.map((entry) => [entry.number, entry]));
    const run = recorder({ pullRequests: [...asks, ...closes], recheck });
    const tally = await sweep({ ...run, context, dryRun: true });
    assert.deepEqual(tally, { "request-rebase": 50, "close-conflict": 25 });
  });
});
