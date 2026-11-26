import { describe, expect, it } from "vitest";
import type { AccountPullRequests, PullRequestItem } from "../connectors";
import type { RunEvent } from "./api";
import { matchedMentionedPullRequests, parsePrUrl, prMentionsInEvents } from "./pr-mentions";

function ev(kind: RunEvent["kind"], text: string, extra: Partial<RunEvent> = {}): RunEvent {
  return {
    id: Math.random().toString(36).slice(2),
    date: "2026-11-26T12:00:00Z",
    kind,
    text,
    ...extra,
  };
}

describe("pr-mentions helpers (AG-123)", () => {
  it("parses GitHub PR and GitLab MR URLs", () => {
    expect(parsePrUrl("https://github.com/acme/web/pull/42.")).toEqual({
      repo: "acme/web",
      number: 42,
      url: "https://github.com/acme/web/pull/42",
    });
    expect(parsePrUrl("https://gitlab.example.com/team/app/-/merge_requests/9")).toEqual({
      repo: "team/app",
      number: 9,
      url: "https://gitlab.example.com/team/app/-/merge_requests/9",
    });
    expect(parsePrUrl("https://github.com/acme/web/issues/42")).toBeNull();
  });

  it("extracts CLI and message PR mentions from timeline events", () => {
    const events: RunEvent[] = [
      ev("user", "Can you check #3877 and https://github.com/acme/web/pull/19? Ignore abc#99."),
      ev("tool", "Bash · gh pr checks 3877", {
        tool: "Bash",
        detail: JSON.stringify({ command: "gh pr view -R acme/api 7 --body 55 && glab mr view 5 -R group/app" }),
      }),
      ev("user", "Rolled back #999", { rolledBack: true }),
    ];
    const mentions = prMentionsInEvents(events);
    expect(mentions).toEqual([
      { repo: "acme/web", number: 19, url: "https://github.com/acme/web/pull/19" },
      { repo: null, number: 3877, url: null },
      { repo: "acme/api", number: 7, url: null },
      { repo: "group/app", number: 5, url: null },
    ]);
  });

  it("matches mentions against loaded account PRs without duplicates", () => {
    const pr19 = { repo: "acme/web", number: 19, title: "Fix login" } as PullRequestItem;
    const pr3877 = { repo: "acme/web", number: 3877, title: "Parity" } as PullRequestItem;
    const prOther = { repo: "acme/web", number: 50, title: "Unrelated" } as PullRequestItem;
    const accounts: AccountPullRequests[] = [
      { id: "gh1", name: "GitHub", login: "me", mine: [pr19, prOther], reviews: [pr3877], watched: [], issues: [], unreadable: [], error: null, errorKind: null },
    ];
    const matched = matchedMentionedPullRequests(
      [
        { repo: "acme/web", number: 19, url: null },
        { repo: null, number: 3877, url: null },
      ],
      accounts,
    );
    expect(matched.map((m) => m.item.number)).toEqual([3877, 19]);
  });
});
