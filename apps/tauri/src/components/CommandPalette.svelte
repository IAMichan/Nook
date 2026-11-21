<script lang="ts">
  // Search everything (Ctrl+K), as the Mac's `SearchPanel`: one field over conversations with Nook, agent sessions and
  // their transcripts, chats of every app, call notes, memories, missed notices, Settings pages and actions. Typing
  // ranks as you go; a chip (or Tab) keeps one kind; ↑/↓ (or Ctrl+N/P) move, Return opens the hit right where it
  // matched, Ctrl+1 to Ctrl+9 open the first nine, Escape (twice with text), the cross or a click beside it closes.
  // Ctrl+Return (or the AI row) searches with AI: the brain plans searches, reads what they find and answers citing
  // them. With nothing typed it shows what you opened lately, your recent searches, the open and settled sessions and
  // how to search more precisely. The query language and ranking are in `search-everything.ts`; the text only the
  // backend holds is searched there (`search-api.ts`).
  import { onMount } from "svelte";
  import { invoke } from "@tauri-apps/api/core";
  import { emit } from "@tauri-apps/api/event";
  import { api } from "../lib/api";
  import { nook, relativeTime } from "../lib/state.svelte";
  import { toast } from "../lib/toast.svelte";
  import { parseRoute, type Route } from "../lib/shell-routes";
  import { onBack } from "../lib/mobile";
  import { appLanguage, tr, type AppLanguage } from "../lib/i18n.svelte";
  import { agents } from "../lib/agents.svelte";
  import { agentNames, type AgentSession, type PastSession } from "../lib/agents";
  import { workspace } from "../lib/workspace/store.svelte";
  import { isActive, projectName, type WorkspaceRun } from "../lib/workspace/api";
  import { groupTitle, pageTitle, sectionTitle, settingsGroup, settingsHost, settingsSections, type SettingsSectionId } from "../lib/settings-pages";
  import {
    answerTokens, backendRequest, citations, cleanAnswer, clearRecent, cycleKind, gather, grouped, highlightRanges, isSettled, keywordQuery,
    loadOpened, loadRecent, looksLikeQuestion, mergeBackend, noticeDocs, openedBonus, orderedByCitation, parseQuery, positiveTerms,
    recentlyOpened, rememberOpened, rememberSearch, search, searchKinds, segments,
    type BackendHit, type NoticeHistoryEntry, type SearchDoc, type SearchHit, type SearchKind,
  } from "../lib/search-everything";
  import { searchApi, type AISource } from "../lib/search-api";
  import { sessionFind } from "../lib/session-find.svelte";
  import { chatFocus } from "../lib/chat-focus.svelte";
  import { whatsapp } from "../lib/whatsapp.svelte";
  import Ico from "./ui/Ico.svelte";
  import FilterChip from "./ui/FilterChip.svelte";
  import ListEmptyNote from "./ui/ListEmptyNote.svelte";
  import StatusPill from "./ui/StatusPill.svelte";
  import AgentMark from "../views/companion/ui/AgentMark.svelte";

  let { onclose, onnavigate, companionEnabled = false }: {
    onclose: () => void;
    onnavigate: (route: Route) => void;
    companionEnabled?: boolean;
  } = $props();

  type Scope = "open" | "settled";
  type Row = { type: "hit"; hit: SearchHit; top: boolean } | { type: "ai"; text: string } | { type: "ask"; text: string };
  /** Search with AI's answer for a question, while it is the one typed. */
  type AIAnswer = {
    question: string;
    phase: "planning" | "reading" | "answered" | "failed" | "noBrain";
    count: number;
    answer: string;
    sources: SearchHit[];
    cited: number[];
  };

  let dialog: HTMLDialogElement;
  let input: HTMLInputElement;
  let list = $state<HTMLDivElement | null>(null);
  let text = $state("");
  let kind = $state<SearchKind | null>(null);
  let scope = $state<Scope | null>(null);
  let index = $state(0);
  /** What the backend found for what is typed: the documents that hold it, with the passage that matched. */
  let found = $state<{ text: string; hits: BackendHit[] }>({ text: "", hits: [] });
  let searchError = $state(false);
  /** Return came before the results were in: open the best hit when they are. */
  let openWhenReady = $state(false);
  let ai = $state<AIAnswer | null>(null);
  let recent = $state<string[]>(loadRecent());
  let opened = $state(loadOpened());
  /** Missed and recent notices from Rust's `notice_history` (empty in preview when unavailable). */
  let notices = $state<NoticeHistoryEntry[]>([]);

  onMount(() => {
    const previous = document.activeElement;
    dialog.showModal();
    input.focus();
    const offBack = onBack(() => { onclose(); return true; });
    // Gathering everything to search: the sessions and Nook's own runs, earlier sessions of every agent, and notices.
    void agents.start();
    if (!agents.history) void agents.loadHistory();
    if (nook.info?.capabilities.terminals) workspace.start().catch(() => {});
    let alive = true;
    invoke<NoticeHistoryEntry[]>("notice_history", { query: "" })
      .then((entries) => { if (alive && Array.isArray(entries)) notices = entries; })
      .catch(() => {});
    return () => {
      alive = false;
      offBack();
      dialog.close();
      if (previous instanceof HTMLElement && previous.isConnected) previous.focus();
    };
  });

  // MARK: What it searches

  type Action = { id: string; title: string; icon: string; also?: string; run: () => void | Promise<void> };

  function openAgents(page: string) {
    agents.select(page);
    onnavigate("agents");
  }

  function openSettings(section: SettingsSectionId) {
    try { localStorage.setItem("settings.section", section); } catch { /* opens on the last page instead */ }
    onnavigate("settings");
    // Settings already on screen takes its subject from the navigate event.
    emit("navigate", `settings:${section}`).catch(() => {});
  }

  /** Things to do, found by their name: the Mac's actions (`searchActions`) and this app's own pages. */
  const actions = $derived.by((): Action[] => [
    { id: "newChat", title: tr("Nieuw gesprek met Nook", "New conversation with Nook"), icon: "square-pen", also: "New Nook Nieuwe Nook", run: async () => { await nook.newNook(); onnavigate("chat"); } },
    { id: "newSession", title: tr("Nieuwe sessie", "New session"), icon: "message-square-plus", run: () => openAgents("new") },
    { id: "pulls", title: "Pull requests", icon: "git-pull-request", run: () => openAgents("pulls") },
    { id: "actions", title: "Actions", icon: "play", run: () => openAgents("actions") },
    { id: "usage", title: tr("Gebruik", "Usage"), icon: "chart-column", run: () => openAgents("usage") },
    ...(nook.info?.capabilities.terminals ? [
      { id: "terminals", title: tr("Alle terminals", "All terminals"), icon: "terminal", run: () => openAgents("terminals") },
      { id: "browser", title: "Browser", icon: "globe", run: () => openAgents("browser") },
      { id: "worktrees", title: "Worktrees", icon: "git-branch", run: () => openAgents("worktrees") },
      { id: "workspace", title: tr("Werkplek openen", "Open workspace"), icon: "layout-grid", run: () => onnavigate("workspace") },
    ] : []),
    { id: "chat", title: tr("Chat openen", "Open chat"), icon: "message-square", run: () => onnavigate("chat") },
    { id: "agents", title: tr("Agents openen", "Open agents"), icon: "messages-square", run: () => onnavigate("agents") },
    { id: "games", title: tr("Gamer Mode openen", "Open Gamer Mode"), icon: "gamepad-2", run: () => onnavigate("games") },
    ...(companionEnabled ? [{ id: "companion", title: tr("Companion openen", "Open companion"), icon: "smartphone", run: () => onnavigate("companion") }] : []),
    { id: "settings", title: tr("Instellingen openen", "Open settings"), icon: "settings", run: () => onnavigate("settings") },
    { id: "instructions", title: tr("Instructies en opgeslagen prompts openen", "Open instructions and saved prompts"), icon: "settings", run: () => openSettings("instructions") },
  ]);
  const actionById = $derived(new Map(actions.map((a) => [`action:${a.id}`, a])));

  /** The Agents list's own choices (pins, settled), as `AgentsTab` keeps them. */
  function inboxState(): { pinned: string[]; settled: string[] } {
    try {
      const v = JSON.parse(localStorage.getItem("nook.agents.inbox") ?? "{}");
      return { pinned: Array.isArray(v.pinned) ? v.pinned : [], settled: Array.isArray(v.settled) ? v.settled : [] };
    } catch { return { pinned: [], settled: [] }; }
  }

  const time = (iso: string | null | undefined) => (iso ? Date.parse(iso) || undefined : undefined);
  const subtitle = (...parts: (string | null | undefined)[]) => parts.filter(Boolean).join(" · ");

  /** The flags of a state, for is: and for the badge in the row. */
  function sessionDoc(id: string, title: string, agent: string, project: string, branch: string | null, date: number | undefined,
    flags: string[], extra: string): SearchDoc {
    return {
      id, kind: "session", title: title || project || agent, subtitle: subtitle(agent, project, branch), text: extra, date, flags,
      facets: { agent, project, ...(branch ? { branch } : {}) }, boost: flags.includes("running") ? 0.3 : 0,
    };
  }

  /** Everything the interface holds itself; what the backend found is merged in per search (`mergeBackend`). */
  const localDocs = $derived.by((): SearchDoc[] => {
    const bonus = openedBonus(opened);
    const marks = inboxState();
    const out: SearchDoc[] = actions.map((a) => ({ id: `action:${a.id}`, kind: "action", title: a.title, text: a.also, boost: 0.2 }));
    for (const id of settingsSections) {
      const host = settingsHost(id);
      out.push({ id: `setting:${id}`, kind: "setting", title: sectionTitle(id),
        subtitle: subtitle(groupTitle(settingsGroup(id)), host === id ? null : pageTitle(host)) });
    }
    // Conversations in the list; the backend adds archived ones and finds every message.
    for (const n of nook.nooks.filter((n) => n.preview || n.title)) {
      const flags = [n.pinned && "pinned", n.archived && "archived", n.status === "working" && "running", n.status === "waiting" && "waiting",
        n.status === "unread" && "unread"].filter((f): f is string => !!f);
      out.push({ id: `conversation:${n.id}`, kind: "conversation", title: n.title, subtitle: n.preview, date: time(n.updated), flags,
        boost: n.pinned ? 0.4 : 0 });
    }
    // Sessions Nook runs, the agents it follows, and every earlier session of every agent.
    const known = new Set<string>();
    for (const r of workspace.runs as WorkspaceRun[]) {
      const key = `run:${r.id}`;
      if (r.providerSessionId) known.add(r.providerSessionId);
      const flags = [isActive(r.status) && "running", r.status === "failed" && "failed", r.status === "waitingApproval" && "waiting",
        r.status === "completed" && "done", r.archived && "archived", (r.archived || (!isActive(r.status) && marks.settled.includes(key))) && "settled",
        marks.pinned.includes(key) && "pinned"].filter((f): f is string => !!f);
      out.push(sessionDoc(key, r.title, workspace.provider(r.provider)?.name ?? r.provider, projectName(r.projectPath), r.branch,
        time(r.updatedAt), flags, r.task));
    }
    for (const s of agents.sessions as AgentSession[]) {
      if (s.status === "detected" || s.id.startsWith("run:")) continue;
      if (s.sessionId) known.add(s.sessionId);
      const flags = [s.status === "running" && "running", s.status === "waiting" && "waiting", s.status === "failed" && "failed",
        s.status === "done" && "done", s.status !== "running" && marks.settled.includes(s.id) && "settled",
        marks.pinned.includes(s.id) && "pinned"].filter((f): f is string => !!f);
      out.push(sessionDoc(s.id, s.summary || s.lastPrompt || s.project, s.name, s.project, null, time(s.updated ?? s.started), flags,
        `${s.lastPrompt}\n${s.lastReply}`));
    }
    for (const p of (agents.history?.sessions ?? []) as PastSession[]) {
      if (p.sessionId && known.has(p.sessionId)) continue;
      out.push(sessionDoc(`past:${p.agent}:${p.sessionId}`, p.title, agentNames[p.agent] ?? p.agent, projectName(p.cwd), p.branch || null,
        time(p.ended), ["done", "settled"], `${p.lastPrompt}\n${p.lastReply}\n${p.model}`));
    }
    // Missed and recent notices from `notice_history`.
    out.push(...noticeDocs(notices));
    // What you open often and lately ranks a little higher.
    return out.map((d) => (bonus[d.id] ? { ...d, boost: (d.boost ?? 0) + bonus[d.id] } : d));
  });
  const docs = $derived(found.text === text ? mergeBackend(localDocs, found.hits) : localDocs);

  const typed = $derived(text.trim());
  const query = $derived(parseQuery(typed));
  const hits = $derived(search(docs, query));
  const visible = $derived(hits.filter((h) => (!kind || h.doc.kind === kind) && (kind !== "session" || !scope || isSettled(h.doc) === (scope === "settled"))));
  const pending = $derived(!!backendRequest(query) && found.text !== text && !searchError);
  /** The AI answer for what is typed, if it is the one asked. */
  const answer = $derived(ai && ai.question === typed ? ai : null);
  /** The words to mark in a passage: what is typed, or with an AI answer the question's words that carry meaning. */
  const snippetQuery = $derived(answer ? parseQuery(keywordQuery(answer.question)) : query);
  const rows = $derived.by((): Row[] => {
    // With an AI answer the list is what it read, the hits it cites first.
    if (answer) return orderedByCitation(answer.sources, answer.cited).map((hit) => ({ type: "hit", hit, top: false }));
    const out: Row[] = [];
    // A question in your own words: asking AI comes first.
    const question = !!typed && looksLikeQuestion(typed);
    if (question) out.push({ type: "ai", text: typed });
    out.push(...grouped(visible, kind).map(({ hit, top }): Row => ({ type: "hit", hit, top })));
    if (typed && !question) out.push({ type: "ai", text: typed });
    if (typed && positiveTerms(query).length) out.push({ type: "ask", text: typed });
    return out;
  });
  const counts = $derived(Object.fromEntries(searchKinds.map((k) => [k, hits.filter((h) => h.doc.kind === k).length])) as Record<SearchKind, number>);

  // The backend searches the text only it holds, a moment after typing stops.
  $effect(() => {
    const now = text;
    const request = backendRequest(parseQuery(now.trim()));
    searchError = false;
    if (!request) { found = { text: now, hits: [] }; return; }
    let stale = false;
    const timer = setTimeout(async () => {
      try {
        const hits = await searchApi.search(request);
        if (!stale) found = { text: now, hits };
      } catch {
        if (!stale) { searchError = true; found = { text: now, hits: [] }; }
      }
    }, 150);
    return () => { stale = true; clearTimeout(timer); };
  });

  $effect(() => {
    void text;
    index = 0;
  });
  $effect(() => {
    if (kind !== "session") scope = null;
  });
  $effect(() => {
    if (index > Math.max(0, rows.length - 1)) index = Math.max(0, rows.length - 1);
  });
  $effect(() => {
    if (openWhenReady && !pending) {
      openWhenReady = false;
      index = 0;
      open(0);
    }
  });
  $effect(() => {
    const at = index;
    list?.querySelector(`[data-index="${at}"]`)?.scrollIntoView({ block: "nearest" });
  });

  // MARK: Opening

  async function open(at: number) {
    const row = rows[at];
    if (!row) return;
    // Searching with AI keeps the panel open: its answer shows here.
    if (row.type === "ai") { void askAI(); return; }
    recent = rememberSearch(text, recent);
    onclose();
    try {
      if (row.type === "ask") return await askNook(row.text);
      opened = rememberOpened(row.hit.doc, Date.now(), opened);
      await openDoc(row.hit.doc);
    } catch (e) {
      toast.error(tr("Kon dit niet openen", "Could not open that item"), e);
    }
  }

  /** Asks Nook in a new conversation: for a search that found nothing, or a question rather than words. */
  async function askNook(question: string) {
    await nook.newNook();
    onnavigate("chat");
    await nook.ask(question);
  }

  /** Goes to what a hit is about, right where it matched (the Mac's `openSearchHit`). */
  async function openDoc(doc: SearchDoc) {
    const id = doc.id;
    const value = id.slice(id.indexOf(":") + 1);
    switch (doc.kind) {
      case "action": await actionById.get(id)?.run(); break;
      case "setting": openSettings(value as SettingsSectionId); break;
      case "conversation":
        if (doc.anchor) chatFocus.show(doc.anchor);
        await nook.select(value);
        onnavigate("chat");
        break;
      case "session":
        // A run that matched in its transcript opens with its find bar on the first words that matched.
        if (id.startsWith("run:") && doc.anchor && doc.snippet) {
          const first = highlightRanges(doc.snippet, query)[0];
          const words = first ? doc.snippet.slice(first[0], first[1]).trim() : "";
          if (words) sessionFind.open(value, words);
        }
        agents.select(id.startsWith("run:") || id.startsWith("past:") ? id : value);
        onnavigate("agents");
        break;
      case "chat": {
        // "chat:<app>:<id>": the Chats tab opens the chat it opened last (`chats.lastOpened`, by the inbox's key) when it
        // comes up; a WhatsApp chat shows at once too. A window event tells a Chats tab already on screen.
        const app = value.slice(0, value.indexOf(":"));
        const chat = value.slice(value.indexOf(":") + 1);
        const key = `${app}#${chat}`;
        try { localStorage.setItem("chats.lastOpened", key); } catch { /* opens on the list instead */ }
        onnavigate("chats");
        window.dispatchEvent(new CustomEvent("nook-open-chat", { detail: key }));
        if (app === "whatsapp") await whatsapp.show(chat);
        break;
      }
      case "note": {
        // A call note reads as a conversation, the way it arrived when the call ended.
        const conversation = await searchApi.openNote(value);
        await nook.select(conversation);
        onnavigate("chat");
        break;
      }
      case "memory": openSettings("memory"); break;
      case "notice": {
        const noticeId = Number(value);
        if (Number.isFinite(noticeId)) invoke("notice_history_seen", { id: noticeId }).catch(() => {});
        const route = doc.route ?? "";
        if (route.startsWith("agent:")) {
          const target = route.slice(6);
          agents.select(target.startsWith("run-") ? `run:${target.slice(4)}` : target);
          onnavigate("agents");
        } else if (route.startsWith("chat:")) {
          const key = route.slice(5);
          try { localStorage.setItem("chats.lastOpened", key); } catch { /* opens on the list instead */ }
          onnavigate("chats");
          window.dispatchEvent(new CustomEvent("nook-open-chat", { detail: key }));
          if (key.startsWith("whatsapp#")) await whatsapp.show(key.slice("whatsapp#".length));
        } else if (route.startsWith("nook:")) {
          await nook.select(route.slice(5));
          onnavigate("chat");
        } else if (route.startsWith("settings:")) {
          openSettings(route.slice(9) as SettingsSectionId);
        } else {
          onnavigate(parseRoute(route || null));
        }
        break;
      }
    }
  }

  // MARK: Search with AI

  /** One search as the AI runs it: the same query language and documents as typing. */
  async function runSearch(queryText: string): Promise<SearchHit[]> {
    const q = parseQuery(queryText);
    const request = backendRequest(q, 40);
    const hits = request ? await searchApi.search(request).catch(() => []) : [];
    return search(mergeBackend(localDocs, hits), q).slice(0, 8);
  }

  const isoDay = (ms: number | undefined) => (ms ? new Date(ms).toISOString().slice(0, 10) : "");

  /** What you opened lately, refreshed with live titles/states when present (`SearchCenter.refreshRecentlyOpened`). */
  const recentDocs = $derived.by((): SearchDoc[] => {
    const byId = new Map(localDocs.map((d) => [d.id, d]));
    return recentlyOpened(opened).map((doc) => byId.get(doc.id) ?? doc);
  });

  async function askAI() {
    const question = typed;
    if (!question) return;
    index = 0;
    const closest = visible.filter((h) => h.doc.kind !== "action" && h.doc.kind !== "setting").slice(0, 10);
    if (!nook.info?.brainReady) { ai = { question, phase: "noBrain", count: 0, answer: "", sources: closest, cited: [] }; return; }
    ai = { question, phase: "planning", count: 0, answer: "", sources: [], cited: [] };
    const still = () => ai?.question === question;
    const planned = await searchApi.plan(question).catch(() => [] as string[]);
    if (!still()) return;
    const queries = [keywordQuery(question), ...planned].filter(Boolean);
    const lists = await Promise.all(queries.map(runSearch));
    if (!still()) return;
    // What stays on this computer (a memory marked local) never reaches a brain elsewhere.
    const sources = gather(lists).filter((h) => nook.info?.brainLocal || !h.doc.flags?.includes("local"));
    if (!sources.length) {
      ai = { question, phase: "answered", count: 0, answer: tr("Ik vond hier niets over in Nook. Probeer andere woorden of vraag het Nook in een gesprek.", "I found nothing about this in Nook. Try other words, or ask Nook in a conversation."), sources: [], cited: [] };
      return;
    }
    ai = { question, phase: "reading", count: sources.length, answer: "", sources, cited: [] };
    const read: AISource[] = sources.map((h) => ({
      kind: h.doc.kind, title: h.doc.title, subtitle: h.doc.subtitle ?? "", date: isoDay(h.doc.passageDate ?? h.doc.date),
      author: h.doc.author ?? "", text: h.doc.snippet || h.doc.subtitle || "",
    }));
    try {
      const reply = cleanAnswer(await searchApi.answer(question, read));
      if (!still()) return;
      ai = { question, phase: "answered", count: sources.length, answer: reply, sources, cited: citations(reply, sources.length) };
    } catch {
      if (still()) ai = { question, phase: "failed", count: sources.length, answer: "", sources, cited: [] };
    }
  }

  /** Goes on in a conversation with Nook about the question, where it can use its tools and follow-ups. */
  async function continueInChat(question: string) {
    recent = rememberSearch(question, recent);
    onclose();
    try { await askNook(question); } catch (e) { toast.error(tr("Kon dit niet openen", "Could not open that item"), e); }
  }

  function chooseBrain() {
    onclose();
    openSettings("brain");
  }

  function submit() {
    if (!typed) return;
    if (pending && !answer) openWhenReady = true;
    else open(index);
  }

  /** Straight to the open or the settled sessions, without a word to search for. */
  function showSessions(next: Scope) {
    text = next === "open" ? "in:sessions -is:settled" : "in:sessions is:settled";
    kind = "session";
    scope = next;
    input.focus();
  }

  function useTip(insert: string) {
    if (insert) text = insert;
    input.focus();
  }

  function move(delta: number) {
    index = Math.min(Math.max(index + delta, 0), Math.max(0, rows.length - 1));
  }

  function keys(e: KeyboardEvent) {
    if (e.isComposing || e.defaultPrevented) return;
    const ctrl = e.ctrlKey || e.metaKey;
    if (e.key === "Escape") {
      // Escape clears what is typed first, then closes.
      if (text) { e.preventDefault(); text = ""; }
      return;
    }
    // Ctrl+Return: search with AI, whichever row is chosen.
    if (e.key === "Enter" && ctrl && !e.shiftKey && !e.altKey) { e.preventDefault(); void askAI(); return; }
    if (e.key === "Enter" && !ctrl && !e.shiftKey && !e.altKey) { e.preventDefault(); submit(); return; }
    if (e.key === "ArrowDown" && !ctrl) { e.preventDefault(); move(1); return; }
    if (e.key === "ArrowUp" && !ctrl) { e.preventDefault(); move(-1); return; }
    if (e.ctrlKey && !e.metaKey && (e.key === "n" || e.key === "p")) { e.preventDefault(); move(e.key === "n" ? 1 : -1); return; }
    if (e.key === "Tab" && !ctrl && !e.altKey && text) {
      e.preventDefault();
      kind = cycleKind(hits, kind, e.shiftKey);
      return;
    }
    // Ctrl+1 to Ctrl+9: the row with that number, counted down the list.
    if (ctrl && !e.altKey && /^[1-9]$/.test(e.key) && text && rows[Number(e.key) - 1]) {
      e.preventDefault();
      index = Number(e.key) - 1;
      open(index);
    }
  }

  // MARK: Look

  const kindTitle = (k: SearchKind) => ({
    conversation: "Nook", session: tr("Sessies", "Sessions"), chat: "Chats", note: tr("Notities", "Notes"), memory: tr("Geheugen", "Memory"),
    notice: tr("Meldingen", "Notices"), setting: tr("Instellingen", "Settings"), action: tr("Acties", "Actions"),
  })[k];
  // "Open" as an adjective (the Mac's `search.sessions.open`): the catalog keys "Open" by English text and holds the verb.
  const openWord: Record<AppLanguage, string> = { nl: "Lopend", en: "Open", de: "Offen", fr: "En cours", es: "Abiertas" };
  const scopeTitle = (s: Scope) => (s === "open" ? openWord[appLanguage()] : tr("Afgehandeld", "Settled"));

  /** A label over the first row of each group: the top hit, then each kind; open and settled sessions apart. */
  function sectionLabel(at: number): string | null {
    if (answer) return at === 0 ? tr("Bronnen", "Sources") : null;
    const group = (row: Row) => {
      if (row.type !== "hit") return "";
      if (row.top) return tr("Beste resultaat", "Top hit");
      if (row.hit.doc.kind === "session") {
        const s = scopeTitle(isSettled(row.hit.doc) ? "settled" : "open");
        return kind === "session" ? s : `${kindTitle("session")} · ${s}`;
      }
      return kindTitle(row.hit.doc.kind);
    };
    const current = group(rows[at]);
    if (!current || !(kind === null || (kind === "session" && scope === null))) return null;
    return at === 0 || group(rows[at - 1]) !== current ? current : null;
  }

  function symbol(doc: SearchDoc): string {
    if (doc.kind === "action") return actionById.get(doc.id)?.icon ?? "settings";
    if (doc.kind === "setting") return "settings";
    if (doc.kind === "note") return "audio-waveform";
    if (doc.kind === "memory") return "brain";
    if (doc.kind === "notice") return "bell";
    if (doc.kind === "chat") return "message-circle";
    return "message-square";
  }

  /** A session's state as its row in the Agents list says it. */
  function attention(doc: SearchDoc): string | null {
    if (doc.kind !== "session" || isSettled(doc)) return null;
    const f = doc.flags ?? [];
    if (f.includes("waiting")) return "approval";
    if (f.includes("failed")) return "failed";
    if (f.includes("running")) return "working";
    if (f.includes("done")) return "finished";
    return null;
  }

  /** The query language, by example; a click starts a search with it. */
  const tips = $derived([
    { example: '"exact words"', text: tr("precies deze woorden, in deze volgorde", "exactly these words, in this order"), insert: '"' },
    { example: "-word", text: tr("laat weg wat dit woord bevat", "leave out what contains this word"), insert: "-" },
    { example: "a OR b", text: tr("het een of het ander", "one or the other"), insert: "" },
    { example: "in:agents  in:chats", text: tr("alleen sessies, chats, notities, geheugen…", "only sessions, chats, notes, memory…"), insert: "in:" },
    { example: "from:me  from:anna", text: tr("wat jij, Nook, een agent of iemand anders schreef", "what you, Nook, an agent or someone else wrote"), insert: "from:" },
    { example: "after:2026-10-01  before:7d", text: tr("na, voor of op een datum (ook 7d, 2w, gisteren)", "after, before or on a date (also 7d, 2w, yesterday)"), insert: "after:" },
    { example: "is:unread  is:settled", text: tr("ongelezen, vastgezet, bezig, mislukt, afgehandeld", "unread, pinned, running, failed, settled"), insert: "is:" },
    { example: "app:  project:  branch:", text: tr("per app, project, branch of agent", "by app, project, branch or agent"), insert: "project:" },
    { example: "/regex/", text: tr("een reguliere expressie", "a regular expression"), insert: "/" },
  ]);

  /** Who wrote the passage, as the row says it. */
  const authorName = (author: string) => (author === "me" ? tr("Jij", "You") : author === "nook" ? "Nook" : author);
  /** A hit's number in the AI answer, as it cites it ([1] is the first source). */
  const sourceNumber = (doc: SearchDoc) => (answer ? answer.sources.findIndex((h) => h.doc.id === doc.id) + 1 || null : null);
  const initials = (name: string) => name.split(/\s+/).filter(Boolean).slice(0, 2).map((w) => w[0]?.toUpperCase() ?? "").join("");
</script>

{#snippet face(doc: SearchDoc, selected: boolean)}
  <!-- A chat's initials, an agent's logo, else the kind's symbol; all in the same slot so the titles line up. -->
  <span class="face">
    {#if doc.kind === "session"}<AgentMark agent={doc.facets?.agent ?? ""} size={22} />
    {:else if doc.kind === "chat"}<span class="initials">{initials(doc.title)}</span>
    {:else}<span class="symbol" class:on={selected}><Ico name={symbol(doc)} size={13} /></span>{/if}
  </span>
{/snippet}

<dialog bind:this={dialog} aria-label={tr("Alles doorzoeken", "Search everything")} onclose={onclose} onkeydown={keys}
  onclick={(e) => { if (e.target === dialog) onclose(); }}>
  <div class="panel">
    <div class="head">
      <label class="field">
        <Ico name="search" size={14} stroke={2} />
        <input bind:this={input} bind:value={text} role="combobox" aria-expanded="true" aria-autocomplete="list" aria-controls="search-everything-results"
          aria-activedescendant={typed && rows.length ? `search-everything-row-${index}` : undefined} autocomplete="off" spellcheck="false"
          aria-label={tr("Zoek in gesprekken, sessies, chats, notities, instellingen…", "Search conversations, sessions, chats, notes, settings…")}
          placeholder={tr("Zoek in gesprekken, sessies, chats, notities, instellingen…", "Search conversations, sessions, chats, notes, settings…")} />
        {#if text}<button class="glyph" aria-label={tr("Wis", "Clear")} onclick={() => { text = ""; input.focus(); }}><Ico name="circle-x" size={14} /></button>{/if}
      </label>
      <button class="glyph close" aria-label={tr("Sluiten", "Close")} onclick={onclose}><Ico name="x" size={14} /></button>
    </div>
    {#if text && !answer}
      <div class="chips">
        <FilterChip label={tr("Alles", "All")} count={hits.length || undefined} selected={kind === null} onclick={() => (kind = null)} />
        {#each searchKinds.filter((k) => counts[k] > 0 || k === kind) as k (k)}
          <FilterChip label={kindTitle(k)} count={counts[k]} selected={kind === k} onclick={() => (kind = kind === k ? null : k)} />
        {/each}
        {#if kind === "session"}
          <span class="rule" aria-hidden="true"></span>
          {#each ["open", "settled"] as const as s (s)}
            <FilterChip label={scopeTitle(s)} selected={scope === s} onclick={() => (scope = scope === s ? null : s)}
              count={scope === null || scope === s ? hits.filter((h) => h.doc.kind === "session" && isSettled(h.doc) === (s === "settled")).length : undefined} />
          {/each}
        {/if}
      </div>
    {/if}
    <div class="body" bind:this={list}>
      {#if !typed}
        <div class="start">
          {#if recentDocs.length}
            <div class="label">{tr("Recent geopend", "Recently opened")}</div>
            {#each recentDocs as doc (doc.id)}
              {@const state = attention(doc)}
              <button class="hit" onclick={() => { opened = rememberOpened(doc, Date.now(), opened); onclose(); openDoc(doc).catch((e) => toast.error(tr("Kon dit niet openen", "Could not open that item"), e)); }}>
                {@render face(doc, false)}
                <span class="text"><span class="top"><span class="title">{doc.title}</span>{#if doc.flags?.includes("unread")}<span class="dot" aria-hidden="true"></span>{/if}<span class="spacer"></span>
                  {#if state}<StatusPill attention={state} />{/if}
                  {#if doc.date && doc.kind !== "setting"}<span class="age">{relativeTime(new Date(doc.date).toISOString())}</span>{/if}</span>
                  {#if doc.subtitle}<span class="sub">{doc.subtitle}</span>{/if}</span>
              </button>
            {/each}
          {/if}
          {#if recent.length}
            <div class="label row-label" class:gap={recentDocs.length > 0}>
              <span>{tr("Recente zoekopdrachten", "Recent searches")}</span>
              <button class="ghost-small" onclick={() => (recent = clearRecent())}>{tr("Wissen", "Clear")}</button>
            </div>
            {#each recent as r (r)}
              <button class="line" onclick={() => { text = r; input.focus(); }}><span class="icon"><Ico name="history" size={13} /></span><span class="name">{r}</span></button>
            {/each}
          {/if}
          <div class="label" class:gap={recent.length > 0 || recentDocs.length > 0}>{tr("Sessies", "Sessions")}</div>
          <button class="line" onclick={() => showSessions("open")}><span class="icon"><Ico name="circle-dashed" size={13} /></span><span class="name">{tr("Lopende sessies: bezig, wachten op jou of klaar", "Open sessions: running, waiting on you or done")}</span></button>
          <button class="line" onclick={() => showSessions("settled")}><span class="icon"><Ico name="archive" size={13} /></span><span class="name">{tr("Afgehandelde sessies", "Settled sessions")}</span></button>
          <div class="label gap">{tr("Zo zoek je preciezer", "Search more precisely")}</div>
          {#each tips as tip (tip.example)}
            <button class="line tip" onclick={() => useTip(tip.insert)}><code>{tip.example}</code><span class="what">{tip.text}</span></button>
          {/each}
        </div>
      {:else}
        {#if searchError}<p class="error" role="alert">{tr("Kon de gesprekken niet doorzoeken. Sluit en probeer het opnieuw.", "Could not search conversations. Close and try again.")}</p>{/if}
        {#if answer}
          <div class="answer">
            <div class="answer-head">
              <Ico name="sparkles" size={12} />
              <span class="answer-title">{tr("Antwoord van AI", "AI answer")}</span>
              <span class="spacer"></span>
              {#if answer.phase === "planning" || answer.phase === "reading"}<span class="busy" aria-hidden="true"></span>{/if}
              {#if answer.phase === "answered"}<button class="ghost-button" onclick={() => continueInChat(answer.question)}>{tr("Verder in gesprek", "Continue in chat")}</button>{/if}
            </div>
            {#if answer.phase === "planning"}<p class="answer-note">{tr("Bedenken waarop te zoeken…", "Working out what to search for…")}</p>
            {:else if answer.phase === "reading"}<p class="answer-note">{tr("{n} resultaten lezen…", "Reading {n} results…", { n: answer.count })}</p>
            {:else if answer.phase === "answered"}
              <p class="answer-text">{#each answerTokens(answer.answer, answer.sources.length) as token, p (p)}{#if token.kind === "cite"}<span class="cite">{token.text}</span>{:else if token.kind === "bold"}<strong>{token.text}</strong>{:else if token.kind === "italic"}<em>{token.text}</em>{:else if token.kind === "code"}<code class="inline-code">{token.text}</code>{:else if token.kind === "link"}<a href={token.href} target="_blank" rel="noopener noreferrer">{token.text}</a>{:else}{token.text}{/if}{/each}</p>
            {:else if answer.phase === "noBrain"}
              <div class="answer-row"><p class="answer-note">{tr("Kies een brein om met AI te zoeken. Dit zijn de resultaten die er het dichtst bij komen.", "Choose a brain to search with AI. These are the closest results.")}</p>
                <button class="ghost-button" onclick={chooseBrain}>{tr("Brein kiezen", "Choose brain")}</button></div>
            {:else}<p class="answer-note">{tr("De AI gaf geen antwoord. Dit zijn de resultaten die er het dichtst bij komen.", "The AI did not answer. These are the closest results.")}</p>{/if}
          </div>
        {/if}
        {#if !answer && !rows.some((r) => r.type === "hit") && !pending}
          <div class="none">
            <ListEmptyNote text={tr("Niets gevonden", "Nothing found")} />
            <p class="detail">{tr("Probeer minder woorden, een ander woord of haal een filter weg.", "Try fewer words, another word, or remove a filter.")}</p>
          </div>
        {/if}
        <div id="search-everything-results" class="rows" role="listbox" aria-label={tr("Resultaten", "Results")}>
          {#each rows as row, i (row.type === "hit" ? (row.top ? "top:" : "") + row.hit.doc.id : row.type)}
            {@const label = sectionLabel(i)}
            {#if label}<div class="label" class:gap={i > 0}>{label}</div>{/if}
            {#if row.type === "hit"}
              {@const doc = row.hit.doc}
              {@const state = attention(doc)}
              <button id={`search-everything-row-${i}`} role="option" aria-selected={i === index} tabindex="-1" class="hit" class:on={i === index}
                data-index={i} onpointermove={() => (index = i)} onclick={() => { index = i; open(i); }}>
                {@render face(doc, i === index)}
                <span class="text">
                  <span class="top">
                    {#if sourceNumber(doc)}<span class="cite">[{sourceNumber(doc)}]</span>{/if}
                    <span class="title">{#each segments(doc.title, row.hit.titleRanges) as piece, p (p)}{#if piece.marked}<mark>{piece.text}</mark>{:else}{piece.text}{/if}{/each}</span>
                    {#if doc.flags?.includes("unread")}<span class="dot" aria-hidden="true"></span>{/if}
                    <span class="spacer"></span>
                    {#if state}<StatusPill attention={state} />{/if}
                    {#if (doc.matches ?? 0) > 1}<span class="muted">{tr("{n} treffers", "{n} matches", { n: doc.matches ?? 0 })}</span>{/if}
                    {#if (doc.passageDate ?? doc.date) && doc.kind !== "action" && doc.kind !== "setting"}<span class="age">{relativeTime(new Date(doc.passageDate ?? doc.date ?? 0).toISOString())}</span>{/if}
                    {#if i === index}<span class="return" aria-hidden="true">↩</span>{/if}
                  </span>
                  {#if doc.snippet}
                    <span class="sub">{#if doc.author && doc.kind !== "setting"}<span class="who">{`${authorName(doc.author)}: `}</span>{/if}{#each segments(doc.snippet, highlightRanges(doc.snippet, snippetQuery)) as piece, p (p)}{#if piece.marked}<b>{piece.text}</b>{:else}{piece.text}{/if}{/each}{#if doc.subtitle && doc.kind !== "conversation"}<span class="place">&nbsp;&nbsp;·&nbsp;&nbsp;{doc.subtitle}</span>{/if}</span>
                  {:else if doc.subtitle}<span class="sub">{doc.subtitle}</span>{/if}
                </span>
              </button>
            {:else if row.type === "ai"}
              <button id={`search-everything-row-${i}`} role="option" aria-selected={i === index} tabindex="-1" class="act" class:on={i === index}
                data-index={i} onpointermove={() => (index = i)} onclick={() => { index = i; open(i); }}>
                <span class="icon accent"><Ico name="sparkles" size={13} /></span>
                <span class="name">{tr("Zoek met AI: {text}", "Search with AI: {text}", { text: row.text })}</span>
                <span class="age" aria-hidden="true">Ctrl ↩</span>
                {#if i === index}<span class="return" aria-hidden="true">↩</span>{/if}
              </button>
            {:else}
              <button id={`search-everything-row-${i}`} role="option" aria-selected={i === index} tabindex="-1" class="act" class:on={i === index}
                data-index={i} onpointermove={() => (index = i)} onclick={() => { index = i; open(i); }}>
                <span class="icon accent"><Ico name="message-square" size={13} /></span>
                <span class="name">{tr("Vraag het Nook: {text}", "Ask Nook: {text}", { text: row.text })}</span>
                {#if i === index}<span class="return" aria-hidden="true">↩</span>{/if}
              </button>
            {/if}
          {/each}
        </div>
      {/if}
    </div>
    <footer>
      <span class="keys">{tr("↑↓ kiezen · ⇥ soort · ↩ openen · Ctrl↩ AI · Ctrl 1–9 direct · esc sluiten", "↑↓ choose · ⇥ kind · ↩ open · Ctrl↩ AI · Ctrl 1–9 jump · esc close")}</span>
      {#if typed}
        <span class="count" role="status">
          {#if pending}<span class="busy small" aria-hidden="true"></span>{tr("Zoeken…", "Searching…")}{:else}{tr("{n} resultaten", "{n} results", { n: visible.length })}{/if}
        </span>
      {/if}
    </footer>
  </div>
</dialog>

<style>
  /* A card at the top of the window, under the header, as wide as 640 allows (`PanelView`'s search overlay). */
  dialog { position: fixed; inset: calc(38px + var(--space-8)) 0 auto; width: min(640px, calc(100vw - 2 * var(--space-12))); max-width: none;
    max-height: calc(100dvh - 38px - var(--space-24)); padding: 0; margin: 0 auto; color: var(--paper); background: var(--graphite);
    border: 1px solid var(--line2); border-radius: var(--radius-sheet); box-shadow: var(--shadow-popover); overflow: hidden; }
  dialog::backdrop { background: transparent; }
  .panel { display: flex; flex-direction: column; max-height: inherit; }
  .head { display: flex; align-items: center; gap: var(--space-4); padding: 0 var(--space-8) 0 var(--space-4); }
  .field { flex: 1; min-width: 0; display: flex; align-items: center; gap: var(--space-6); height: 44px; padding: 0 var(--space-8); color: var(--text3); }
  .field input { flex: 1; min-width: 0; padding: 0; border: none !important; background: none; box-shadow: none !important; font: var(--text-body); color: var(--paper); }
  .field input::placeholder { color: var(--text3); }
  .glyph { display: inline-flex; align-items: center; justify-content: center; width: 22px; height: 22px; padding: 0; flex: none; border: none;
    background: transparent; border-radius: var(--radius-control); color: var(--text3); }
  .glyph:hover { background: var(--row-hover); color: var(--paper); }
  .close { color: var(--text2); }
  .chips { display: flex; align-items: center; gap: var(--space-6); padding: var(--space-2) var(--space-12) var(--space-8); overflow-x: auto; scrollbar-width: none; }
  /* Kind chips match macOS `NookFilterChip`: filled with `smoke` at rest, `iris` when chosen, `text-label`. */
  .chips :global(.chip) { padding: calc(var(--space-4) + 1px) calc(var(--space-8) + var(--space-2)); background: var(--smoke); border-color: transparent; color: var(--text-strong); font: var(--text-label); }
  .chips :global(.chip:hover:not(:disabled)) { background: var(--smoke); color: var(--paper); }
  .chips :global(.chip.selected), .chips :global(.chip.selected:hover:not(:disabled)) { background: var(--iris); color: var(--on-iris); }
  .chips :global(.chip .count) { font: var(--text-caption); opacity: 0.7; }
  .rule { width: 1px; height: 16px; background: var(--line2); flex: none; }
  .body { min-height: 0; max-height: 440px; overflow-y: auto; scrollbar-width: none; border-top: 1px solid var(--border); padding: var(--space-6); }
  .start { display: flex; flex-direction: column; gap: var(--space-4); }
  .label { padding: var(--space-2) var(--space-8); font: var(--text-label); color: var(--text3); }
  .label.gap { margin-top: var(--space-8); }
  .line, .act { display: flex; align-items: center; gap: var(--space-8); width: 100%; height: 30px; padding: 0 var(--space-8); text-align: left;
    border: none; background: transparent; border-radius: var(--radius-control); color: var(--text-strong); font: var(--text-body); }
  .line:hover { background: var(--row-hover); }
  .line.tip { height: 28px; gap: var(--space-12); }
  .icon { width: 18px; display: inline-flex; justify-content: center; color: var(--text3); flex: none; }
  .icon.accent { color: var(--iris); }
  .name { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .tip code { width: 210px; flex: none; font: var(--text-code); color: var(--paper); white-space: pre; overflow: hidden; text-overflow: ellipsis; }
  .what { flex: 1; min-width: 0; font: var(--text-detail); color: var(--text2); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .rows { display: flex; flex-direction: column; gap: var(--space-2); }
  .hit { display: flex; align-items: flex-start; gap: var(--space-8); width: 100%; padding: var(--space-6) var(--space-8); text-align: left; border: none;
    background: transparent; border-radius: var(--radius-control); color: var(--paper); }
  .act { color: var(--paper); height: 34px; }
  .hit.on, .act.on { background: var(--smoke); }
  .face { width: 26px; min-height: 18px; display: inline-flex; align-items: center; justify-content: center; flex: none; }
  .symbol { display: inline-flex; color: var(--text3); }
  .symbol.on { color: var(--iris); }
  .initials { width: 26px; height: 26px; border-radius: 999px; display: inline-flex; align-items: center; justify-content: center;
    background: var(--smoke); color: var(--text-strong); font: var(--text-label); }
  .who { font: var(--text-label); color: var(--text-strong); }
  .sub b { font-weight: 600; color: var(--paper); background: color-mix(in srgb, var(--iris) 22%, transparent); border-radius: var(--radius-chat-join); }
  .place { color: var(--text3); }
  .muted { font: var(--text-caption); color: var(--text-muted); white-space: nowrap; flex: none; }
  .cite { font: var(--text-label); color: var(--iris); flex: none; }
  .row-label { display: flex; align-items: center; justify-content: space-between; }
  .ghost-small { padding: var(--space-2) var(--space-8); border: none; background: transparent; border-radius: var(--radius-control);
    font: var(--text-label); color: var(--text2); }
  .ghost-small:hover { background: var(--row-hover); color: var(--paper); }
  /* `SmallGhostButton`: 30 high, the strong text, a graphite fill under the pointer. */
  .ghost-button { height: 30px; padding: 0 10px; border: none; background: transparent; border-radius: var(--radius-control);
    font: var(--text-emphasis); color: var(--text2); white-space: nowrap; flex: none; }
  .ghost-button:hover { background: var(--graphite); color: var(--paper); }
  .start .hit:hover { background: var(--row-hover); }
  .answer { display: flex; flex-direction: column; gap: var(--space-6); margin: 0 0 var(--space-6); padding: var(--space-8);
    background: var(--smoke); border: 1px solid var(--line2); border-radius: var(--radius-control); }
  .answer-head { display: flex; align-items: center; gap: var(--space-6); color: var(--iris); }
  .answer-title { font: var(--text-label); color: var(--text-strong); }
  .answer-note { margin: 0; font: var(--text-detail); color: var(--text2); }
  .answer-text { margin: 0; font: var(--text-body); color: var(--paper); white-space: pre-wrap; user-select: text; }
  .answer-text strong { font: var(--text-emphasis); font-weight: 600; }
  .answer-text .inline-code { font: var(--text-code); padding: 0 var(--space-4); border-radius: var(--radius-chat-join); background: var(--field); color: var(--paper); }
  .answer-text a { color: var(--blue); text-decoration: underline; text-underline-offset: 2px; }
  .answer-row { display: flex; align-items: center; gap: var(--space-8); }
  .answer-row .answer-note { flex: 1; }
  .busy { width: 12px; height: 12px; border-radius: 999px; border: 2px solid var(--line2); border-top-color: var(--text2); animation: spin 0.8s linear infinite; flex: none; }
  .busy.small { width: 10px; height: 10px; }
  @keyframes spin { to { transform: rotate(360deg); } }
  .text { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: var(--space-2); }
  .top { display: flex; align-items: center; gap: var(--space-6); min-width: 0; }
  .title { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font: var(--text-body); }
  mark { font: var(--text-emphasis); color: var(--paper); background: color-mix(in srgb, var(--iris) 22%, transparent); border-radius: var(--radius-chat-join); }
  .dot { width: 6px; height: 6px; border-radius: 999px; background: var(--iris); flex: none; }
  .spacer { flex: 1; min-width: var(--space-8); }
  .age, .return { font: var(--text-caption); color: var(--text3); white-space: nowrap; flex: none; }
  .return { color: var(--text2); }
  .sub { font: var(--text-detail); color: var(--text2); overflow: hidden; text-overflow: ellipsis; display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; }
  .none { display: flex; flex-direction: column; gap: var(--space-6); padding: var(--space-12) var(--space-12) var(--space-6); }
  .none .detail { margin: 0; font: var(--text-detail); color: var(--text3); }
  .error { margin: var(--space-8); font: var(--text-detail); color: var(--coral); }
  footer { display: flex; align-items: center; gap: var(--space-8); height: 30px; flex: none; padding: 0 var(--space-12); border-top: 1px solid var(--border);
    font: var(--text-caption); color: var(--text3); }
  .keys { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .count { display: inline-flex; align-items: center; gap: var(--space-6); white-space: nowrap; }
</style>
