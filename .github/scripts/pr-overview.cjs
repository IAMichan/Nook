// One comment at the top of every pull request that keeps itself up to date: where the pull request stands and what
// has to happen before it can merge. Loaded by .github/workflows/pr-overview.yml from the default branch; it reads the
// pull request, its check runs and reviews through the API and never runs pull request code.
//
// `summarize` and `render` are pure (tested in pr-overview.test.cjs); `run` does the API calls.

const MARKER = "<!-- nook-pr-overview -->";
const REQUIRED_APPROVALS = 1;

// Check runs this overview knows by name. CI jobs are "<area> / <job>" (reusable workflows) or a plain name.
const GATE = "Check";
const DESCRIPTION = "Description follows template";
const AGENT_CONTEXT = "Agent context does not grow";
// Bookkeeping jobs that say nothing about the pull request itself.
const IGNORED = new Set(["label", "Collect pull requests", "Publish overview", "Welcome", "Changes"]);
const IGNORED_PREFIXES = ["Label ("];

const FAILED = new Set(["failure", "cancelled", "timed_out", "action_required", "startup_failure"]);

function state(run) {
  if (!run) return "missing";
  if (run.status !== "completed") return "running";
  if (FAILED.has(run.conclusion)) return "failed";
  return "passed"; // success, neutral, skipped
}

// The newest run per name: a re-run or new push replaces the older result.
function latestByName(checkRuns) {
  const latest = new Map();
  for (const run of checkRuns) {
    const known = latest.get(run.name);
    if (!known || new Date(run.started_at ?? 0) >= new Date(known.started_at ?? 0)) latest.set(run.name, run);
  }
  return latest;
}

// Approvals still standing: the last decisive review of each reviewer counts.
function approvals(reviews, author) {
  const last = new Map();
  for (const review of reviews) {
    const login = review.user?.login;
    if (!login || login === author) continue;
    if (["APPROVED", "CHANGES_REQUESTED", "DISMISSED"].includes(review.state)) last.set(login, review.state);
  }
  const values = [...last.values()];
  return {
    approved: values.filter((s) => s === "APPROVED").length,
    changesRequested: [...last.entries()].filter(([, s]) => s === "CHANGES_REQUESTED").map(([login]) => login),
  };
}

function labelValue(labels, prefix) {
  const label = labels.find((name) => name.startsWith(prefix));
  return label ? label.slice(prefix.length) : null;
}

function summarize({ pr, checkRuns, reviews }) {
  const labels = (pr.labels ?? []).map((label) => (typeof label === "string" ? label : label.name));
  const runs = latestByName(checkRuns);
  const gate = runs.get(GATE);
  const description = runs.get(DESCRIPTION);
  const agentContext = runs.get(AGENT_CONTEXT);

  const jobs = [...runs.values()].filter(
    (run) =>
      ![GATE, DESCRIPTION, AGENT_CONTEXT].includes(run.name) &&
      !IGNORED.has(run.name) &&
      !IGNORED_PREFIXES.some((prefix) => run.name.startsWith(prefix)),
  );
  const failedJobs = jobs.filter((run) => state(run) === "failed").sort((a, b) => a.name.localeCompare(b.name));
  const runningJobs = jobs.filter((run) => state(run) === "running");
  const areas = [...new Set(jobs.filter((run) => run.name.includes(" / ")).map((run) => run.name.split(" / ")[0]))].sort();

  const review = approvals(reviews, pr.user?.login);

  return {
    number: pr.number,
    draft: Boolean(pr.draft),
    conflicts: pr.mergeable_state === "dirty",
    behind: pr.mergeable_state === "behind",
    size: labelValue(labels, "size:"),
    vouch: labelValue(labels, "vouch:"),
    areaLabels: labels.filter((name) => name.startsWith("area: ")).map((name) => name.slice(6)).sort(),
    ciAreas: areas,
    gate: { state: state(gate), url: gate?.html_url },
    // While a job still runs, `Check` has not reported yet; show it as running rather than missing.
    ciRunning: runningJobs.length > 0,
    failedJobs: failedJobs.map((run) => ({ name: run.name, url: run.html_url })),
    description: { state: state(description), url: description?.html_url },
    agentContext: agentContext ? { state: state(agentContext), url: agentContext.html_url } : null,
    approved: review.approved,
    changesRequested: review.changesRequested,
    keepOpen: labels.includes("keep open"),
    stale: labels.includes("stale"),
  };
}

const VOUCH_TEXT = {
  trusted: "trusted contributor",
  unvouched: "new contributor (welcome!)",
  denounced: "denounced: a maintainer will look closely",
};

function link(text, url) {
  return url ? `[${text}](${url})` : text;
}

function ciLine(model) {
  if (model.draft) return "Not started: CI does not run on drafts.";
  const { state: gateState, url } = model.gate;
  if (gateState === "failed") {
    if (model.failedJobs.length === 0) return `${link("Failing", url)}.`;
    return `Failing: ${model.failedJobs.map((job) => link(job.name, job.url)).join(", ")}.`;
  }
  if (gateState === "passed") {
    return model.ciAreas.length ? `Passed (${model.ciAreas.join(", ")}).` : "Passed (no build needed for this change).";
  }
  if (gateState === "running" || model.ciRunning) {
    const failing = model.failedJobs.length
      ? ` Already failing: ${model.failedJobs.map((job) => link(job.name, job.url)).join(", ")}.`
      : "";
    return `Running.${failing}`;
  }
  return "No result yet. If this stays, update the branch with main so it runs the current CI.";
}

function nextSteps(model) {
  const steps = [];
  if (model.draft) {
    steps.push("Mark the pull request **ready for review** when it is done; that starts CI.");
  }
  if (model.conflicts) steps.push("Resolve the **merge conflicts** with `main`.");
  if (!model.draft && model.description.state === "failed") {
    steps.push(
      `Fill in every section of the **description template** (${link("see what is missing", model.description.url)}).`,
    );
  }
  if (!model.draft && model.agentContext?.state === "failed") {
    steps.push(
      `\`AGENTS.md\` or \`CLAUDE.md\` grew: shorten it, or ask a maintainer for the \`agent-context-increase\` label (${link("details", model.agentContext.url)}).`,
    );
  }
  if (!model.draft && (model.failedJobs.length > 0 || model.gate.state === "failed")) {
    steps.push(
      model.failedJobs.length
        ? `Fix the failing CI job${model.failedJobs.length > 1 ? "s" : ""}: ${model.failedJobs.map((job) => link(job.name, job.url)).join(", ")}.`
        : `Fix the failing ${link("CI check", model.gate.url)}.`,
    );
  }
  if (!model.draft && model.gate.state === "missing" && !model.ciRunning) {
    steps.push("Update the branch with `main` (the **Update branch** button) so the current CI runs.");
  }
  if (model.changesRequested.length) {
    steps.push(`Address the changes requested by ${model.changesRequested.map((login) => `@${login}`).join(", ")}.`);
  }
  const ciGreen = model.gate.state === "passed";
  if (!model.draft && model.approved < REQUIRED_APPROVALS && model.changesRequested.length === 0) {
    steps.push(
      ciGreen
        ? "Waiting for a maintainer review. Nothing to do for now."
        : "A maintainer reviews once CI is green.",
    );
  }
  if (steps.length === 0) {
    steps.push(
      ciGreen && model.description.state !== "failed"
        ? "**Ready to merge.**"
        : "Waiting for CI. Nothing to do for now.",
    );
  }
  return steps;
}

function render(model, repoUrl = "https://github.com/IAMichan/nook") {
  const rows = [];
  if (model.size) rows.push(["Size", `\`${model.size}\``]);
  if (model.vouch) rows.push(["Author", VOUCH_TEXT[model.vouch] ?? model.vouch]);
  if (model.areaLabels.length) rows.push(["Areas", model.areaLabels.join(", ")]);
  rows.push(["CI", ciLine(model)]);
  if (!model.draft) {
    const description = {
      passed: "Follows the template.",
      failed: link("Incomplete", model.description.url) + ".",
      running: "Being checked.",
      missing: "Not checked yet.",
    }[model.description.state];
    rows.push(["Description", description]);
  }
  const reviewText =
    model.changesRequested.length > 0
      ? `Changes requested (${model.changesRequested.length}).`
      : `${model.approved} of ${REQUIRED_APPROVALS} approval${REQUIRED_APPROVALS > 1 ? "s" : ""}.`;
  rows.push(["Review", reviewText]);
  if (model.stale && !model.keepOpen) rows.push(["Activity", "Marked `stale`: push or comment to keep it open."]);

  const lines = [
    MARKER,
    "### Pull request overview",
    "",
    "| | |",
    "|---|---|",
    ...rows.map(([key, value]) => `| ${key} | ${value} |`),
    "",
    "**Next steps**",
    "",
    ...nextSteps(model).map((step) => `- ${step}`),
    "",
    `<sub>Updates itself on every push, review and CI result. How CI works: [docs/CI.md](${repoUrl}/blob/HEAD/docs/CI.md).</sub>`,
  ];
  return lines.join("\n");
}

// Finds the pull request a workflow_run belongs to. GitHub leaves `pull_requests` empty for forks, so fall back to
// the open pull request whose head is this commit.
async function findPullNumber({ github, context }) {
  const payload = context.payload;
  if (payload.pull_request) return payload.pull_request.number;
  const run = payload.workflow_run;
  if (!run) return null;
  if (run.pull_requests?.length) return run.pull_requests[0].number;
  const pulls = await github.paginate(github.rest.pulls.list, { ...context.repo, state: "open", per_page: 100 });
  return pulls.find((pull) => pull.head.sha === run.head_sha)?.number ?? null;
}

// The overview comments on a pull request, oldest first.
function overviewComments(comments) {
  return comments
    .filter((comment) => comment.user?.type === "Bot" && comment.body?.startsWith(MARKER))
    .sort((a, b) => a.id - b.id);
}

async function run({ github, context, core }) {
  const number = await findPullNumber({ github, context });
  if (!number) {
    core.info("No open pull request for this event.");
    return;
  }
  const { data: pr } = await github.rest.pulls.get({ ...context.repo, pull_number: number });
  if (pr.state !== "open") {
    core.info(`#${number} is ${pr.state}.`);
    return;
  }
  if (pr.user?.type === "Bot") {
    core.info(`#${number} is by a bot; no overview.`);
    return;
  }
  const checkRuns = await github.paginate(
    github.rest.checks.listForRef,
    { ...context.repo, ref: pr.head.sha, per_page: 100 },
    (response) => response.data,
  );
  const reviews = await github.paginate(github.rest.pulls.listReviews, {
    ...context.repo,
    pull_number: number,
    per_page: 100,
  });
  const body = render(summarize({ pr, checkRuns, reviews }), pr.base.repo.html_url);

  const comments = await github.paginate(github.rest.issues.listComments, {
    ...context.repo,
    issue_number: number,
    per_page: 100,
  });
  const ours = overviewComments(comments);
  const existing = ours[0];
  if (existing?.body === body) {
    core.info(`#${number}: overview unchanged.`);
  } else if (existing) {
    await github.rest.issues.updateComment({ ...context.repo, comment_id: existing.id, body });
    core.info(`#${number}: overview updated.`);
  } else {
    await github.rest.issues.createComment({ ...context.repo, issue_number: number, body });
    core.info(`#${number}: overview posted.`);
  }

  // Runs are not serialized (a cancelled run would show as a failed check on the pull request), so two runs can both
  // post a first comment. Keep the oldest and delete the rest; every run reads the current state, so any copy is right.
  const after = existing
    ? ours
    : overviewComments(
        await github.paginate(github.rest.issues.listComments, { ...context.repo, issue_number: number, per_page: 100 }),
      );
  for (const duplicate of after.slice(1)) {
    await github.rest.issues
      .deleteComment({ ...context.repo, comment_id: duplicate.id })
      .catch((error) => {
        if (error.status !== 404) throw error;
      });
    core.info(`#${number}: removed duplicate overview ${duplicate.id}.`);
  }
}

module.exports = { MARKER, summarize, render, nextSteps, run, findPullNumber, overviewComments };
