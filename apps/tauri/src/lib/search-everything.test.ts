import { describe, expect, it } from "vitest";
import {
  answerPieces, answerTokens, backendRequest, citations, cleanAnswer, cycleKind, gather, grouped, highlightRanges,
  keywordQuery, looksLikeQuestion, mergeBackend, normalizeApp, noticeDocs, orderedByCitation, parseDate, parseQuery,
  recentlyOpened, rememberOpened, rememberSearch, removeFilter, search, searchKinds, segments,
  type BackendHit, type NoticeHistoryEntry, type SearchDoc,
} from "./search-everything";

const now = new Date(2026, 10, 19, 12).getTime();
const day = 86400000;
const docs: SearchDoc[] = [
  { id: "conversation:1", kind: "conversation", title: "Release notes for 1.4", date: now - day, flags: ["pinned"] },
  {
    id: "run:1", kind: "session", title: "Fix the checkout", subtitle: "Claude Code · shop · main", date: now - 2 * day,
    facets: { agent: "Claude Code", project: "shop", branch: "main" }, flags: ["running"],
  },
  {
    id: "past:1", kind: "session", title: "Write the release script", subtitle: "Codex · tools", date: now - 40 * day,
    facets: { agent: "Codex", project: "tools" }, flags: ["settled"],
  },
  {
    id: "run:archived", kind: "session", title: "Archive migration notes", subtitle: "Claude Code · infra", date: now - 15 * day,
    facets: { agent: "Claude Code", project: "infra" }, flags: ["archived", "settled"],
  },
  { id: "setting:appearance", kind: "setting", title: "Appearance", text: "Nook" },
  { id: "action:usage", kind: "action", title: "Usage" },
];

describe("search everything", () => {
  it("reads words, phrases, exclusions, OR/|, quoted filters, from: and app:", () => {
    const q = parseQuery('"exact words" -draft a OR b | c in:agents from:"Anna de Vries" app:wa via:Claude is:unread -is:settled project:Shop after:2026-10-01 /re.ex/', now);
    expect(q.alternatives).toEqual([["exact words", "a"], ["b"], ["c"]]);
    expect(q.excluded).toEqual(["draft"]);
    expect(q.kinds).toEqual(["session"]);
    expect(q.from).toEqual(["anna de vries"]);
    expect(q.app).toEqual(["whatsapp", "claude"]);
    expect(q.is).toEqual(["unread"]);
    expect(q.isNot).toEqual(["settled"]);
    expect(q.facets).toEqual([["project", "shop"]]);
    expect(q.after).toBe(new Date(2026, 9, 1).getTime());
    expect(q.regex?.source).toBe("re.ex");
    expect(q.filters.map((f) => f.label)).toEqual([
      "-draft",
      "in:agents",
      "from:Anna de Vries",
      "app:wa",
      "app:Claude",
      "is:unread",
      "-is:settled",
      "project:Shop",
      "after:2026-10-01",
      "/re.ex/",
    ]);
  });

  it("normalizes multilingual from: me aliases, app aliases and removes filter pills cleanly", () => {
    const q = parseQuery('van:ik app:imessage deploy');
    expect(q.from).toEqual(["me"]);
    expect(q.app).toEqual(["messages"]);
    expect(normalizeApp("twitter")).toBe("x");
    expect(normalizeApp("tg")).toBe("telegram");

    const afterRemove = removeFilter('from:"Anna de Vries" app:wa invoice', q.filters[0] ? { raw: 'from:"Anna de Vries"' } : { raw: "" });
    expect(afterRemove).toBe("app:wa invoice");
  });

  it("takes relative dates", () => {
    expect(parseDate("7d", now)).toBe(new Date(2026, 10, 12).getTime());
    expect(parseDate("yesterday", now)).toBe(new Date(2026, 10, 18).getTime());
    expect(parseDate("soon", now)).toBeUndefined();
  });

  it("ranks title matches first and filters by kind, flag, facet, app, from and date", () => {
    expect(search(docs, parseQuery("release", now), now).map((h) => h.doc.id)).toEqual(["conversation:1", "past:1"]);
    expect(search(docs, parseQuery("release in:sessions", now), now).map((h) => h.doc.id)).toEqual(["past:1"]);
    expect(search(docs, parseQuery("release -script", now), now).map((h) => h.doc.id)).toEqual(["conversation:1"]);
    expect(search(docs, parseQuery("in:agents -is:settled", now), now).map((h) => h.doc.id)).toEqual(["run:1"]);
    expect(search(docs, parseQuery("in:agents is:archived", now), now).map((h) => h.doc.id)).toEqual(["run:archived"]);
    expect(search(docs, parseQuery("app:claude", now), now).map((h) => h.doc.id)).toEqual(["run:1", "run:archived"]);
    expect(search(docs, parseQuery("from:codex", now), now).map((h) => h.doc.id)).toEqual(["past:1"]);
    expect(search(docs, parseQuery("branch:main", now), now).map((h) => h.doc.id)).toEqual(["run:1"]);
    expect(search(docs, parseQuery("after:7d", now), now).map((h) => h.doc.id).sort()).toEqual(["conversation:1", "run:1"]);
    expect(search(docs, parseQuery("checkout OR usage", now), now).map((h) => h.doc.id).sort()).toEqual(["action:usage", "run:1"]);
    expect(search(docs, parseQuery("/^fix/", now), now).map((h) => h.doc.id)).toEqual(["run:1"]);
    expect(search(docs, parseQuery("in:chats", now), now)).toEqual([]);
    expect(search(docs, parseQuery("", now), now)).toEqual([]);
  });

  it("asks the backend for words, authors, apps and its kinds, and merges what it found", () => {
    expect(backendRequest(parseQuery("invoice -spam from:anna app:wa in:chats"))).toEqual({
      alternatives: [["invoice"]], excluded: ["spam"], regex: null, from: ["anna"], app: ["whatsapp"], kinds: ["chat"], limit: 200,
    });
    expect(backendRequest(parseQuery("app:whatsapp"))).toEqual({
      alternatives: [], excluded: [], regex: null, from: [], app: ["whatsapp"], kinds: [], limit: 200,
    });
    expect(backendRequest(parseQuery("in:settings appearance"))).toBeNull();
    expect(backendRequest(parseQuery("in:notices approval"))).toBeNull();
    expect(backendRequest(parseQuery("is:unread"))).toBeNull();
    const hit = (id: string, kind: string, score = 1, app?: string): BackendHit => ({
      id, kind, title: "Taxes", subtitle: "", date: null, flags: [], facets: app ? { app } : {}, boost: 0, snippet: "the invoice for March",
      author: "me", passageDate: null, anchor: "m1", matches: 2, score,
    });
    const merged = mergeBackend(docs, [hit("run:1", "session", 2.5), hit("chat:whatsapp:1", "chat", 5.0, "WhatsApp")]);
    expect(merged.find((d) => d.id === "run:1")?.snippet).toBe("the invoice for March");
    expect(merged.find((d) => d.id === "chat:whatsapp:1")?.contentHit).toBe(true);
    // Higher backend BM25 score ranks chat:whatsapp:1 ahead of run:1.
    const found = search(merged, parseQuery("invoice"), now).map((h) => h.doc.id);
    expect(found).toEqual(["chat:whatsapp:1", "run:1"]);
    // app:wa matches WhatsApp chat hit.
    expect(search(merged, parseQuery("app:wa"), now).map((h) => h.doc.id)).toEqual(["chat:whatsapp:1"]);
    // from: keeps only what matched that author.
    expect(search(merged, parseQuery("from:me"), now).map((h) => h.doc.id).sort()).toEqual(["chat:whatsapp:1", "run:1"]);
  });

  it("indexes missed notices with unread flags, localized in: aliases, facets and routes", () => {
    const entries: NoticeHistoryEntry[] = [
      { id: 1, key: "agent:run-42", kind: "waiting", title: "Permission needed", detail: "Run cargo test", context: "Claude Code", date: now - 60_000, route: "agent:run-42", seen: false },
      { id: 2, key: "chat:whatsapp#anna", kind: "info", title: "Anna", detail: "Are we still on for lunch?", context: "WhatsApp", date: now - 300_000, route: "chat:whatsapp#anna", seen: true },
      { id: 3, key: "", kind: "info", title: "", detail: "", context: "", date: now, route: "", seen: true },
    ];
    const notices = noticeDocs(entries);
    expect(notices).toHaveLength(2);
    expect(notices[0]).toMatchObject({
      id: "notice:1",
      kind: "notice",
      title: "Permission needed",
      subtitle: "Run cargo test · Claude Code",
      flags: ["unread", "waiting"],
      facets: { app: "Claude Code" },
      route: "agent:run-42",
    });
    expect(searchKinds.indexOf("notice")).toBeGreaterThan(searchKinds.indexOf("memory"));
    expect(searchKinds.indexOf("notice")).toBeLessThan(searchKinds.indexOf("setting"));

    const all = [...docs, ...notices];
    expect(search(all, parseQuery("in:notices", now), now).map((h) => h.doc.id)).toEqual(["notice:1", "notice:2"]);
    expect(search(all, parseQuery("in:meldingen is:unread", now), now).map((h) => h.doc.id)).toEqual(["notice:1"]);
    expect(search(all, parseQuery("in:mitteilungen lunch", now), now).map((h) => h.doc.id)).toEqual(["notice:2"]);
    expect(search(all, parseQuery("in:avisos app:whatsapp", now), now).map((h) => h.doc.id)).toEqual(["notice:2"]);
    expect(search(all, parseQuery("in:notices app:wa", now), now).map((h) => h.doc.id)).toEqual(["notice:2"]);
    expect(search(all, parseQuery("cargo", now), now).map((h) => h.doc.id)).toEqual(["notice:1"]);

    const log = rememberOpened(notices[0], now, {});
    expect(recentlyOpened(log)[0].route).toBe("agent:run-42");
  });

  it("reads questions for Search with AI and its citations", () => {
    expect(looksLikeQuestion("when does the flight leave")).toBe(true);
    expect(looksLikeQuestion("flight lisbon")).toBe(false);
    expect(keywordQuery("When does the flight to Lisbon leave?")).toBe("flight OR lisbon OR leave");
    expect(citations("It leaves at 9:40 [2], booked by you [1, 2] [9].", 3)).toEqual([2, 1]);
    expect(orderedByCitation(["a", "b", "c"], [3, 1])).toEqual(["c", "a", "b"]);
    expect(answerPieces("At 9:40 [2].", 2)).toEqual([{ text: "At 9:40 ", cite: false }, { text: "[2]", cite: true }, { text: ".", cite: false }]);
    expect(cleanAnswer("<think>hmm</think>\n```md\nThe release is **Friday** [1].\n```")).toBe("The release is **Friday** [1].");
    expect(answerTokens("Move to **Friday** (`main`), *confirmed* by [Anna](https://example.com) [2] [9].", 2)).toEqual([
      { kind: "text", text: "Move to " },
      { kind: "bold", text: "Friday" },
      { kind: "text", text: " (" },
      { kind: "code", text: "main" },
      { kind: "text", text: "), " },
      { kind: "italic", text: "confirmed" },
      { kind: "text", text: " by " },
      { kind: "link", text: "Anna", href: "https://example.com" },
      { kind: "text", text: " " },
      { kind: "cite", text: "[2]" },
      { kind: "text", text: " [9]." },
    ]);
    const hits = search(docs, parseQuery("e", now), now);
    expect(gather([hits, hits]).every((h) => h.doc.kind !== "action" && h.doc.kind !== "setting")).toBe(true);
  });

  it("remembers searches and what was opened", () => {
    expect(rememberSearch("Flight", rememberSearch("hotel", rememberSearch("flight")))).toEqual(["Flight", "hotel"]);
    const log = rememberOpened(docs[1], now, rememberOpened(docs[0], now - 1000, {}));
    expect(recentlyOpened(log).map((d) => d.id)).toEqual(["run:1", "conversation:1"]);
    expect(rememberOpened(docs[5], now, log)).toBe(log);
  });

  it("marks the matched words, accents folded", () => {
    const text = "Réglages and reglages";
    const ranges = highlightRanges(text, parseQuery("reglages"));
    expect(ranges).toEqual([[0, 8], [13, 21]]);
    expect(segments(text, ranges)).toEqual([
      { text: "Réglages", marked: true }, { text: " and ", marked: false }, { text: "reglages", marked: true },
    ]);
  });

  it("puts the best hit on top, then each kind with open sessions first", () => {
    const hits = search(docs, parseQuery("e", now), now);
    const rows = grouped(hits, null);
    expect(rows[0].top).toBe(true);
    expect(grouped(search(docs, parseQuery("the", now), now), "session").map((r) => r.hit.doc.id)).toEqual(["run:1", "past:1"]);
    expect(grouped(hits, "session").every((r) => !r.top && r.hit.doc.kind === "session")).toBe(true);
  });

  it("cycles through the kinds that have hits", () => {
    const hits = search(docs, parseQuery("e", now), now);
    expect(cycleKind(hits, null)).toBe("conversation");
    expect(cycleKind(hits, null, true)).toBe("action");
    expect(cycleKind([], "session")).toBeNull();
  });
});
