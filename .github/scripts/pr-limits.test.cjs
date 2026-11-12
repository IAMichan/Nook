const test = require("node:test");
const assert = require("node:assert/strict");
const { decide, vouchedLogins } = require("./pr-limits.cjs");

const DAY = 24 * 60 * 60 * 1000;
const NOW = Date.parse("2026-11-12T12:00:00Z");

function pr({ labels = ["vouch:unvouched"], mergeable = "CONFLICTING", idleDays = 0, author = "newcomer", isDraft = false } = {}) {
  return {
    number: 1,
    isDraft,
    mergeable,
    author: { login: author },
    updatedAt: new Date(NOW - idleDays * DAY).toISOString(),
    labels: { nodes: labels.map((name) => ({ name })) },
  };
}

test("decide: asks an unvouched, conflicting pull request to rebase once", () => {
  assert.equal(decide(pr(), new Set(), NOW), "request-rebase");
  assert.equal(decide(pr({ mergeable: "MERGEABLE" }), new Set(), NOW), "skip");
  // Mergeability not computed yet: wait for the next run.
  assert.equal(decide(pr({ mergeable: "UNKNOWN" }), new Set(), NOW), "skip");
});

test("decide: closes only after 7 idle days with the label, and clears it once resolved", () => {
  const labels = ["vouch:unvouched", "needs rebase"];
  assert.equal(decide(pr({ labels, idleDays: 6 }), new Set(), NOW), "skip");
  assert.equal(decide(pr({ labels, idleDays: 7 }), new Set(), NOW), "close-conflict");
  assert.equal(decide(pr({ labels, idleDays: 30, mergeable: "MERGEABLE" }), new Set(), NOW), "clear-rebase");
  assert.equal(decide(pr({ labels, idleDays: 30, mergeable: "UNKNOWN" }), new Set(), NOW), "skip");
});

test("decide: never touches trusted, vouched, kept-open or draft pull requests", () => {
  assert.equal(decide(pr({ labels: ["vouch:trusted"] }), new Set(), NOW), "skip");
  assert.equal(decide(pr({ author: "Friend" }), new Set(["friend"]), NOW), "skip");
  assert.equal(decide(pr({ labels: ["vouch:unvouched", "keep open"] }), new Set(), NOW), "skip");
  assert.equal(decide(pr({ isDraft: true }), new Set(), NOW), "skip");
  // A label left from before the author was vouched or the PR was kept open is removed.
  assert.equal(decide(pr({ labels: ["vouch:unvouched", "needs rebase", "keep open"], idleDays: 30 }), new Set(), NOW), "clear-rebase");
  assert.equal(decide(pr({ labels: ["vouch:trusted", "needs rebase"], idleDays: 30 }), new Set(), NOW), "clear-rebase");
});

test("vouchedLogins: reads entries, skips comments and denounced people", () => {
  const logins = vouchedLogins("# comment\ngithub:Alice\n-github:mallory spam\n\ngithub:bob  # note\n");
  assert.deepEqual([...logins].sort(), ["alice", "bob"]);
  assert.equal(vouchedLogins("").size, 0);
});
