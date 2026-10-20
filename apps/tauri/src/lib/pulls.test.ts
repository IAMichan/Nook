import { describe, expect, it } from "vitest";
import type { AccountPullRequests, PullRequestItem } from "./connectors";
import { renderMarkdown } from "./markdown";
import {
  activeCount, activitySentence, apply, authors, chosenMethod, defaultFilter, diffLines, eventLabel, isActive, matches,
  noteText, unreadable,
} from "./pulls";

const item = (number: number, extra: Partial<PullRequestItem> = {}): PullRequestItem => ({
  repo: "acme/web",
  number,
  title: "Fix the parser",
  url: null,
  draft: false,
  updated: null,
  author: "ada",
  ci: "passing",
  state: "open",
  ...extra,
});

const account = (extra: Partial<AccountPullRequests> = {}): AccountPullRequests => ({
  id: "github",
  name: "GitHub",
  login: "me",
  mine: [],
  reviews: [],
  error: null,
  errorKind: null,
  watched: [],
  unreadable: [],
  ...extra,
});

describe("pull request filter", () => {
  it("shows open pull requests by default and counts changed choices", () => {
    const f = defaultFilter();
    expect(matches(f, item(1))).toBe(true);
    expect(matches(f, item(2, { state: "merged" }))).toBe(false);
    expect(activeCount(f)).toBe(0);
    expect(isActive(f)).toBe(false);
    const g = { ...f, state: "all" as const, author: "ada", status: "failing" as const };
    expect(activeCount(g)).toBe(3);
    expect(matches(g, item(3, { state: "closed", ci: "failing" }))).toBe(true);
    expect(matches(g, item(4, { ci: "pending" }))).toBe(false);
    expect(isActive(defaultFilter("x"))).toBe(true);
  });

  it("searches words, authors and exact numbers", () => {
    const f = (query: string) => defaultFilter(query);
    expect(matches(f("parser @ADA"), item(12))).toBe(true);
    expect(matches(f("#12"), item(12))).toBe(true);
    expect(matches(f("#12"), item(123))).toBe(false);
    // A bare number may also be part of the text (a repository named web2), as on the Mac.
    expect(matches(f("12"), item(123))).toBe(true);
    expect(matches(f("77"), item(123))).toBe(false);
    expect(matches(f("web parser"), item(5))).toBe(true);
    expect(matches(f("nope"), item(5))).toBe(false);
  });

  it("filters drafts and groups, and keeps an account's error", () => {
    const a = account({ mine: [item(1, { draft: true })], reviews: [item(2)], watched: [item(3)], error: "Expired" });
    const drafts = apply({ ...defaultFilter(), draft: "drafts" }, a);
    expect([drafts.mine.length, drafts.reviews.length, drafts.watched.length]).toEqual([1, 0, 0]);
    const watched = apply({ ...defaultFilter(), scope: "watched" }, a);
    expect([watched.mine.length, watched.reviews.length, watched.watched.length]).toEqual([0, 0, 1]);
    expect(watched.error).toBe("Expired");
  });

  it("lists authors by count, then name", () => {
    const list = authors([account({ mine: [item(1, { author: "zed" }), item(2, { author: "Bob" })], watched: [item(3, { author: "zed" }), item(4, { author: "" })] })]);
    expect(list).toEqual(["zed", "Bob"]);
  });

  it("names watched entries no readable account could search", () => {
    const a = account({ unreadable: ["typo", "secret"] });
    const b = account({ id: "github.werk", unreadable: ["typo"] });
    expect(unreadable([a, b], ["acme", "typo", "secret"])).toEqual(["typo"]);
    expect(unreadable([account({ error: "x", unreadable: ["typo"] })], ["typo"])).toEqual([]);
  });
});

describe("pull request detail", () => {
  it("words notes, events and activities", () => {
    expect(noteText(null)).toBe("Klaar om te mergen.");
    expect(noteText("conflict")).toBe("Er is een merge-conflict met de basisbranch.");
    expect(activitySentence("labeled", "bug")).toBe("voegde het label bug toe");
    expect(activitySentence("closed", "")).toBe("sloot deze pull request");
    const base = { id: "x", author: "ada", body: "", date: null, url: null };
    expect(eventLabel({ ...base, kind: "review", state: "CHANGES_REQUESTED" })).toEqual({ text: "vroeg om wijzigingen", tone: "bad" });
    expect(eventLabel({ ...base, kind: "lineComment", path: "a.rs", line: 3 }).text).toBe("reageerde op a.rs:3");
  });

  it("keeps the chosen merge method only when the repository allows it", () => {
    expect(chosenMethod("squash", ["merge", "squash"])).toBe("squash");
    expect(chosenMethod("squash", ["rebase"])).toBe("rebase");
    expect(chosenMethod(null, [])).toBe("merge");
  });

  it("splits a diff into kinds", () => {
    expect(diffLines("@@ -1 +1 @@\n-a\n+b\n c").map((l) => l.kind)).toEqual(["hunk", "remove", "add", "context"]);
  });

  it("never lets GitHub's text become raw html", () => {
    // Review bodies come from anyone who can comment; the core rewrites GitHub's HTML, and what is left is escaped.
    expect(renderMarkdown('<img src=x onerror="alert(1)">')).not.toContain("<img");
    const link = renderMarkdown('[x](https://a.b/"onmouseover="alert(1))');
    expect(link).not.toContain('"onmouseover');
    expect(renderMarkdown("[x](javascript:alert(1))")).not.toContain("href");
  });
});
