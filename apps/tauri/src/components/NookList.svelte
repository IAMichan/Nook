<script lang="ts">
  // All your Nooks, as the Mac's `NookList` (`NookConversationList.swift`): a head whose tabs are the two parts of the
  // list (conversations, and the tasks Nook runs on its own) with the new-Nook button, a search, then "For you": a card
  // with what asks something of you (a new answer, a plan waiting for your yes, one still working), each with its badge
  // and the line that says what it did. Below it the pinned ones and the rest by age, one line each (title and how long
  // ago; the rest is on the hover card), and the archive docked at the foot of the list, opening upwards. A scheduled
  // task's run shows only while it asks something of you (or when pinned, or found by a search). Pin and archive appear
  // on hover in the badge's place; right-click for the rest; Ctrl- or Shift-click picks several, with a bar to act on them.
  import { onMount, tick } from "svelte";
  import Ico from "./ui/Ico.svelte";
  import Menu, { type MenuItem } from "./ui/Menu.svelte";
  import CountBadge from "./ui/CountBadge.svelte";
  import StatusPill from "./ui/StatusPill.svelte";
  import { ago } from "../views/agents/time";
  import { api } from "../lib/api";
  import { nook, relativeTime } from "../lib/state.svelte";
  import { toast } from "../lib/toast.svelte";
  import { ask } from "../lib/confirm.svelte";
  import { conversationSections, dayBucket, recoverDeletedConversation } from "../lib/conversation-list";
  import { conversationMarkdown } from "../lib/conversation-export";
  import { tr } from "../lib/i18n.svelte";
  import type { ConversationSummary } from "../lib/types";
  import type { Target } from "../lib/inbox";
  import { tabBadge } from "../lib/nook-tasks";
  import { automationApi, type TaskView } from "../lib/workspace/automation";
  import NookTasks from "./NookTasks.svelte";

  let { onopen }: { onopen?: (target: Target) => void } = $props();
  // How long ago each row was touched, kept current while the list is open.
  let now = $state(Date.now());
  $effect(() => {
    const timer = setInterval(() => (now = Date.now()), 30_000);
    return () => clearInterval(timer);
  });

  /// Conversations and scheduled tasks as two tabs, so they never mix.
  let part = $state<"conversations" | "scheduled">("conversations");
  let tasks = $state<TaskView[] | null>(null);
  const badge = $derived(tasks ? tabBadge(tasks, nook.nooks) : { waiting: 0, fresh: false });
  const nookTaskCount = $derived(tasks?.filter((t) => t.target.type === "nook").length ?? 0);

  // Automation runs in the desktop app only; where it is missing, the list has no Scheduled tab.
  $effect(() => {
    let stop: (() => void) | undefined;
    let live = true;
    const load = () => automationApi.overview().then((o) => { if (live) tasks = o.tasks; }).catch(() => { if (live) tasks = null; });
    load();
    automationApi.onChanged(load).then((off) => { if (live) stop = off; else off(); }).catch(() => {});
    return () => { live = false; stop?.(); };
  });

  function groupTitle(id: string): string {
    switch (id) {
      case "today": return tr("Vandaag", "Today");
      case "yesterday": return tr("Gisteren", "Yesterday");
      case "previous7": return tr("Afgelopen 7 dagen", "Previous 7 days");
      default: return tr("Ouder", "Older");
    }
  }

  type SearchState = { kind: "idle" } | { kind: "loading" } | { kind: "error" } | { kind: "ready"; items: ConversationSummary[] };
  let query = $state("");
  let search = $state<SearchState>({ kind: "idle" });
  let retry = $state(0);
  let loading = $state(true);
  let listError = $state(false);
  let pending = $state(false);
  let itemsElement = $state<HTMLDivElement | undefined>();
  const deleted = new Set<string>();
  /// Deleted with Undo still on screen: hidden right away, removed for good once the undo time is over.
  let hidden = $state<Set<string>>(new Set());
  const UNDO_MS = 7000;
  /// The archive, loaded with the list; its shelf at the foot opens upwards.
  let archived = $state<ConversationSummary[]>([]);
  let showArchived = $state(false);
  /// The Nook being renamed in its row, and the name typed so far.
  let renaming = $state<string | null>(null);
  let nameDraft = $state("");
  /// The Nooks picked with Ctrl- or Shift-click, and the row a Shift-click extends from.
  let picked = $state<Set<string>>(new Set());
  let anchorId: string | null = null;
  let menu = $state<{ item: ConversationSummary; at: DOMRect } | null>(null);

  const searching = $derived(!!query.trim());
  const source = $derived(searching ? (search.kind === "ready" ? search.items : []) : nook.nooks);
  const visible = $derived(source.filter((item) => !hidden.has(item.id)));
  const sections = $derived(conversationSections(visible.filter((i) => !i.archived), { searching, activeId: nook.activeId }));
  const groups = $derived.by(() => {
    const ids = ["today", "yesterday", "previous7", "older"] as const;
    return ids.map((id) => ({ id, items: sections.rest.filter((i) => dayBucket(i.updated, new Date(now)) === id) })).filter((g) => g.items.length);
  });
  const shelf = $derived((searching ? visible.filter((i) => i.archived) : archived).filter((i) => !hidden.has(i.id)));
  /// The rows as shown, top to bottom: what select all and a Shift-click range go by.
  const list = $derived([...sections.attention, ...sections.pinned, ...groups.flatMap((g) => g.items), ...(showArchived ? shelf : [])]);
  const all = $derived(new Map([...visible, ...shelf].map((i) => [i.id, i])));

  onMount(() => { refresh(); });
  async function refresh() {
    loading = true;
    listError = false;
    try { await nook.refreshList(); }
    catch { listError = true; }
    finally { loading = false; }
  }

  // The archive follows the list: every change to it (archiving, a new answer) loads the shelf again.
  $effect(() => {
    void nook.nooks;
    void retry;
    api.nooks(true).then((a) => (archived = a)).catch(() => {});
  });

  $effect(() => {
    const q = query.trim();
    retry;
    search = q ? { kind: "loading" } : { kind: "idle" };
    if (!q) return;
    let stale = false;
    const timer = setTimeout(async () => {
      try {
        const items = await api.searchNooks(q);
        if (!stale) search = { kind: "ready", items };
      } catch { if (!stale) search = { kind: "error" }; }
    }, 150);
    return () => { stale = true; clearTimeout(timer); };
  });

  // Picks that left the list (deleted, filtered out) are dropped.
  $effect(() => {
    const ids = new Set(list.map((i) => i.id));
    if ([...picked].some((id) => !ids.has(id))) picked = new Set([...picked].filter((id) => ids.has(id)));
  });

  // An already-running store event may finish loading the removed ID after deletion.
  $effect(() => {
    if (nook.activeId && deleted.has(nook.activeId)) {
      nook.activeId = null;
      nook.active = null;
    }
  });

  async function select(id: string) {
    try { await nook.select(id); }
    catch (e) { toast.error(tr("Kon het gesprek niet openen", "Could not open conversation"), e); }
  }

  /// A click on a row: opens it, or with Ctrl, Shift or while picking, picks it.
  function click(e: MouseEvent, item: ConversationSummary) {
    if (e.shiftKey && (anchorId || picked.size)) {
      const ids = list.map((i) => i.id);
      const from = ids.indexOf(anchorId ?? [...picked][0]);
      const to = ids.indexOf(item.id);
      if (from >= 0 && to >= 0) {
        picked = new Set([...picked, ...ids.slice(Math.min(from, to), Math.max(from, to) + 1)]);
        return;
      }
    }
    if (e.ctrlKey || e.metaKey || e.shiftKey || picked.size) {
      const next = new Set(picked);
      if (next.has(item.id)) next.delete(item.id); else next.add(item.id);
      picked = next;
      anchorId = item.id;
      return;
    }
    select(item.id);
  }

  async function newNook() {
    try { await nook.newNook(); }
    catch (e) { toast.error(tr("Kon geen nieuwe Nook maken", "Could not create Nook"), e); }
  }

  /// Delete key: the row goes at once and the toast offers Undo for a few seconds.
  async function deleteWithUndo(item: ConversationSummary) {
    if (hidden.has(item.id)) return;
    const index = list.findIndex((row) => row.id === item.id);
    const wasActive = nook.activeId === item.id;
    hidden = new Set(hidden).add(item.id);
    let state: "waiting" | "undone" | "deleted" = "waiting";
    const unhide = () => {
      const next = new Set(hidden);
      next.delete(item.id);
      hidden = next;
    };
    if (wasActive) {
      const next = list.find((row) => row.id !== item.id && !hidden.has(row.id));
      if (next) await select(next.id);
      else { nook.activeId = null; nook.active = null; }
    }
    const timer = setTimeout(async () => {
      if (state !== "waiting") return;
      state = "deleted";
      try {
        await api.deleteNook(item.id);
        deleted.add(item.id);
        await nook.refreshList();
      } catch (e) {
        toast.error(tr("Kon het gesprek niet verwijderen", "Could not delete conversation"), e);
      } finally { unhide(); }
    }, UNDO_MS);
    toast.withAction(tr("“{title}” verwijderd", "Deleted “{title}”", { title: item.title }), {
      label: tr("Ongedaan maken", "Undo"),
      run: () => {
        if (state !== "waiting") return;
        state = "undone";
        clearTimeout(timer);
        unhide();
        if (wasActive) select(item.id);
      },
    });
    await tick();
    focusRow(Math.min(index, list.length - 1));
  }

  /// Changes one or more Nooks' flags, then the list.
  async function setFlags(ids: string[], flags: { pinned?: boolean; archived?: boolean; unread?: boolean }) {
    if (pending || !ids.length) return;
    pending = true;
    try {
      for (const id of ids) await api.setNookFlags(id, flags);
      await nook.refreshList();
      retry++;
    } catch (e) {
      toast.error(flags.archived !== undefined
        ? (flags.archived ? tr("Kon het gesprek niet archiveren", "Could not archive conversation") : tr("Kon het gesprek niet terugzetten", "Could not restore conversation"))
        : flags.pinned !== undefined
          ? (flags.pinned ? tr("Kon het gesprek niet vastzetten", "Could not pin conversation") : tr("Kon het gesprek niet losmaken", "Could not unpin conversation"))
          : tr("Kon het gesprek niet aanpassen", "Could not change conversation"), e);
    } finally { pending = false; }
  }

  /// Delete after a yes, as the Mac's context menu does (`confirmDelete`).
  async function confirmDelete(ids: string[]) {
    const items = ids.map((id) => all.get(id)).filter((i): i is ConversationSummary => !!i && i.status !== "working");
    if (!items.length) return;
    const yes = await ask(items.length === 1
      ? { question: tr("“{title}” verwijderen?", "Delete “{title}”?", { title: items[0].title }), detail: tr("Het gesprek en de berichten worden van deze computer verwijderd.", "The conversation and its messages are removed from this computer."), confirmTitle: tr("Verwijderen", "Delete") }
      : { question: tr("{n} verwijderen?", "Delete {n}?", { n: items.length }), detail: tr("De gesprekken en hun berichten worden van deze computer verwijderd.", "The conversations and their messages are removed from this computer."), confirmTitle: tr("Verwijderen", "Delete") });
    if (!yes) return;
    pending = true;
    try {
      for (const item of items) {
        await api.deleteNook(item.id);
        deleted.add(item.id);
        await recoverDeletedConversation(nook, item.id);
      }
      picked = new Set();
      retry++;
    } catch (e) {
      toast.error(tr("Kon het gesprek niet verwijderen", "Could not delete conversation"), e);
    } finally { pending = false; }
  }

  async function copyMarkdown(id: string) {
    try {
      const conversation = await api.nook(id);
      if (!conversation) return;
      await navigator.clipboard.writeText(conversationMarkdown(conversation));
      toast.success(tr("Gekopieerd", "Copied"));
    } catch (e) { toast.error(tr("Kon niet kopiëren", "Could not copy"), e); }
  }

  function startRename(item: ConversationSummary) {
    nameDraft = item.title;
    renaming = item.id;
    tick().then(() => itemsElement?.querySelector<HTMLInputElement>(".rename")?.select());
  }

  /// Keeps the new name and ends renaming; a second call (Enter, then the field losing focus) does nothing.
  async function commitRename(id: string) {
    if (renaming !== id) return;
    renaming = null;
    const title = nameDraft.trim();
    if (!title || title === all.get(id)?.title) return;
    try { await api.setNookFlags(id, { title }); await nook.refreshList(); }
    catch (e) { toast.error(tr("Kon de naam niet aanpassen", "Could not rename conversation"), e); }
  }

  function menuFor(item: ConversationSummary): MenuItem[][] {
    const busy = item.status === "working";
    return [
      [
        { label: tr("Hernoem", "Rename"), icon: "pencil", onselect: () => startRename(item) },
        ...(!item.archived ? [{ label: item.pinned ? tr("Losmaken", "Unpin") : tr("Vastzetten", "Pin"), icon: item.pinned ? "pin-off" : "pin", onselect: () => setFlags([item.id], { pinned: !item.pinned }) }] : []),
        { label: tr("Kopieer gesprek als Markdown", "Copy conversation as Markdown"), icon: "copy", onselect: () => copyMarkdown(item.id) },
        { label: item.archived ? tr("Terugzetten", "Restore") : tr("Archiveren", "Archive"), icon: "archive", disabled: busy, onselect: () => setFlags([item.id], { archived: !item.archived }) },
      ],
      [{ label: tr("Verwijderen", "Delete"), icon: "trash-2", destructive: true, disabled: busy, onselect: () => confirmDelete([item.id]) }],
    ];
  }

  function focusRow(index: number) {
    itemsElement?.querySelectorAll<HTMLButtonElement>(".conversation")[index]?.focus();
  }

  function rowKeys(e: KeyboardEvent, item: ConversationSummary) {
    const index = list.findIndex((row) => row.id === item.id);
    if (e.key === "ArrowDown" || e.key === "ArrowUp" || e.key === "Home" || e.key === "End") {
      e.preventDefault();
      focusRow(e.key === "Home" ? 0 : e.key === "End" ? list.length - 1 : Math.max(0, Math.min(list.length - 1, index + (e.key === "ArrowDown" ? 1 : -1))));
    } else if (e.key === "Delete" && !e.shiftKey && !e.ctrlKey && !e.altKey) {
      e.preventDefault();
      deleteWithUndo(item);
    } else if (e.key === "F2") {
      e.preventDefault();
      startRename(item);
    } else if ((e.key === "F10" && e.shiftKey) || e.key === "ContextMenu") {
      e.preventDefault();
      menu = { item, at: (e.currentTarget as HTMLElement).getBoundingClientRect() };
    }
  }

  // Ctrl+A picks every row while picking; Escape ends it.
  function windowKeys(e: KeyboardEvent) {
    if (!picked.size || e.defaultPrevented) return;
    if (e.key === "Escape") { e.preventDefault(); picked = new Set(); }
    else if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "a" && !(e.target as HTMLElement)?.closest("input, textarea")) {
      e.preventDefault();
      picked = new Set(list.map((i) => i.id));
    }
  }

  // MARK: Hover card

  /// The row the hover card is for, and where it is: the card opens beside the list after a short rest.
  let hover = $state<{ item: ConversationSummary; rect: DOMRect } | null>(null);
  let hoverTimer: ReturnType<typeof setTimeout> | undefined;
  function hoverIn(e: PointerEvent, item: ConversationSummary) {
    const rect = (e.currentTarget as HTMLElement).getBoundingClientRect();
    clearTimeout(hoverTimer);
    hoverTimer = setTimeout(() => (hover = { item, rect }), hover ? 80 : 450);
  }
  function hoverOut() {
    clearTimeout(hoverTimer);
    hoverTimer = setTimeout(() => (hover = null), 120);
  }
  $effect(() => () => clearTimeout(hoverTimer));

  /// The state as the agents show it (`AgentStatusBadge`).
  const pill = (item: ConversationSummary) => (item.status === "working" ? "working" : item.status === "waiting" ? "approval" : item.status === "unread" ? "ready" : null);
  const statusText = (item: ConversationSummary) =>
    item.status === "working" ? tr("aan het werk…", "working…")
    : item.status === "waiting" ? tr("wacht op jou", "waiting for you")
    : item.status === "unread" ? tr("klaar · {time}", "done · {time}", { time: relativeTime(item.updated) })
    : relativeTime(item.updated);

  // MARK: Several picked

  const pickedItems = $derived([...picked].map((id) => all.get(id)).filter((i): i is ConversationSummary => !!i));
  const allPinned = $derived(pickedItems.length > 0 && pickedItems.every((i) => i.pinned));
  const allArchived = $derived(pickedItems.length > 0 && pickedItems.every((i) => i.archived));
  const anyUnread = $derived(pickedItems.some((i) => i.status === "unread"));
  const idle = $derived(pickedItems.filter((i) => i.status !== "working"));
  const allPicked = $derived(list.length > 0 && list.every((i) => picked.has(i.id)));
</script>

<svelte:window onkeydown={windowKeys} />

{#snippet row(item: ConversationSummary, inCard: boolean)}
  {@const compact = item.status === "idle"}
  {@const receded = compact && item.id !== nook.activeId}
  {#if renaming === item.id}
    <!-- The title being renamed, in its row: Enter or clicking away keeps it, Escape drops it. -->
    <input class="rename" bind:value={nameDraft} aria-label={tr("Hernoem", "Rename")}
      onkeydown={(e) => { if (e.key === "Enter") { e.preventDefault(); commitRename(item.id); } else if (e.key === "Escape") { e.preventDefault(); renaming = null; } }}
      onblur={() => commitRename(item.id)} />
  {:else}
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <div class="item" class:active={item.id === nook.activeId} class:picked={picked.has(item.id)} class:card-row={inCard}
      onpointerenter={(e) => hoverIn(e, item)} onpointerleave={hoverOut}>
      <button class="conversation" class:compact aria-current={item.id === nook.activeId ? "true" : undefined} aria-pressed={picked.size ? picked.has(item.id) : undefined}
        onclick={(e) => click(e, item)} onkeydown={(e) => rowKeys(e, item)}
        oncontextmenu={(e) => { e.preventDefault(); hover = null; menu = { item, at: new DOMRect(e.clientX, e.clientY, 0, 0) }; }}>
        <span class="top">
          {#if picked.size}<span class="check" aria-hidden="true"><Ico name={picked.has(item.id) ? "circle-check" : "circle"} size={14} /></span>{/if}
          <span class="title" class:receded class:archived={item.archived}>{item.title}</span>
          {#if item.pinned}<span class="mark" aria-hidden="true"><Ico name="pin" size={10} /></span>{/if}
          {#if item.scheduledTask}<span class="mark" title={tr("Geplande taak", "Scheduled task")}><Ico name="clock" size={10} /></span>{/if}
          <span class="grow"></span>
          <span class="slot">
            {#if pill(item)}<StatusPill attention={pill(item)!} />{:else}<span class="meta">{ago(item.updated, now)}</span>{/if}
          </span>
        </span>
        <!-- A settled Nook keeps to one line; what asks something of you says what it did underneath. -->
        {#if !compact}<span class="preview">{item.preview || statusText(item)}</span>{/if}
      </button>
      <span class="hover-actions">
        {#if !item.archived}
          <button class="row-button" title={item.pinned ? tr("Losmaken", "Unpin") : tr("Vastzetten", "Pin")} aria-label={item.pinned ? tr("Losmaken", "Unpin") : tr("Vastzetten", "Pin")} disabled={pending}
            onclick={() => setFlags([item.id], { pinned: !item.pinned })}><Ico name={item.pinned ? "pin-off" : "pin"} size={13} /></button>
        {/if}
        {#if item.status !== "working"}
          <button class="row-button" title={item.archived ? tr("Terugzetten", "Restore") : tr("Archiveren", "Archive")} aria-label={item.archived ? tr("Terugzetten", "Restore") : tr("Archiveren", "Archive")} disabled={pending}
            onclick={() => setFlags([item.id], { archived: !item.archived })}><Ico name="archive" size={13} /></button>
        {/if}
      </span>
    </div>
  {/if}
{/snippet}

<aside class="list" aria-label={tr("Gesprekken", "Conversations")}>
  <!-- The Mac's head (`PanelTabHeader`): Conversations and Scheduled as tabs, the new-Nook button on the right. -->
  <div class="head">
    <div class="tabs" role="tablist" aria-label={tr("Gesprekken of geplande taken", "Conversations or scheduled tasks")}>
      <button role="tab" aria-selected={part === "conversations"} class:on={part === "conversations"} onclick={() => (part = "conversations")}>{tr("Gesprekken", "Conversations")}</button>
      {#if tasks}
        <button role="tab" aria-selected={part === "scheduled"} class:on={part === "scheduled"} onclick={() => { part = "scheduled"; picked = new Set(); }} title={nookTaskCount ? tr("{n} taken die Nook uit zichzelf doet", "{n} tasks Nook runs on its own", { n: nookTaskCount }) : undefined}>
          {tr("Gepland", "Scheduled")}
          {#if badge.waiting}<span class="count waiting" aria-label={tr("{n} wachten op jou", "{n} waiting for you", { n: badge.waiting })}>{badge.waiting}</span>
          {:else if badge.fresh}<span class="fresh" aria-label={tr("Nieuw antwoord", "New answer")}></span>{/if}
        </button>
      {/if}
    </div>
    <span class="grow"></span>
    <button class="new-nook" class:on={!nook.active?.messages.length} onclick={newNook} title={tr("Nieuwe Nook (Ctrl+N)", "New Nook (Ctrl+N)")} aria-label={tr("Nieuwe Nook", "New Nook")}><Ico name="square-pen" size={16} /></button>
  </div>
  <label class="search"><Ico name="search" size={14} /><input aria-label={tr("Gesprekken zoeken", "Search conversations")} placeholder={tr("Zoek in Nooks", "Search Nooks")} title={tr("Gesprekken zoeken (Ctrl+F)", "Search conversations (Ctrl+F)")} bind:value={query} onkeydown={(e) => { if (e.key === "ArrowDown" && list.length) { e.preventDefault(); focusRow(0); } }} />{#if query}<button class="ghost" aria-label={tr("Zoekopdracht wissen", "Clear search")} onclick={() => query = ""}>×</button>{/if}</label>
  {#if part === "scheduled" && tasks}
    <div class="items"><NookTasks {tasks} {query} {onopen} /></div>
  {:else}
  <div class="items" bind:this={itemsElement} aria-busy={searching ? search.kind === "loading" : loading}>
    {#if searching && search.kind === "loading" || !searching && loading && !list.length}
      <p class="state" role="status">{searching ? tr("Gesprekken doorzoeken…", "Searching conversations…") : tr("Gesprekken laden…", "Loading conversations…")}</p>
    {:else if searching && search.kind === "error" || !searching && listError}
      <div class="state" role="alert"><p>{searching ? tr("Kon de gesprekken niet doorzoeken.", "Could not search conversations.") : tr("Kon de gesprekken niet laden.", "Could not load conversations.")}</p><button class="ghost" onclick={() => searching ? retry++ : refresh()}>{tr("Probeer opnieuw", "Try again")}</button></div>
    {/if}
    <div class="scroll">
      {#if sections.attention.length}
        <!-- "For you": what asks something of you, on a card of its own on top. -->
        <div class="for-you">
          <div class="for-you-head"><span>{tr("Voor jou", "For you")}</span><CountBadge count={sections.attention.length} /></div>
          {#each sections.attention as item (item.id)}{@render row(item, true)}{/each}
        </div>
      {/if}
      {#if sections.pinned.length}
        <h2 class="section-label">{tr("Vastgezet", "Pinned")}</h2>
        {#each sections.pinned as item (item.id)}{@render row(item, false)}{/each}
      {/if}
      {#each groups as group (group.id)}
        <h2 class="section-label" class:gap={sections.pinned.length > 0 || group !== groups[0]}>{groupTitle(group.id)}</h2>
        {#each group.items as item (item.id)}{@render row(item, false)}{/each}
      {/each}
      {#if !sections.attention.length && !sections.pinned.length && !groups.length && (searching ? search.kind === "ready" : !loading && !listError)}
        {#if searching || shelf.length}
          <p class="note">{tr("Niets gevonden.", "Nothing found.")}</p>
        {:else}
          <div class="list-empty"><Ico name="messages-square" size={26} stroke={1.6} /><p>{tr("Nog geen Nooks", "No Nooks yet")}</p><span>{tr("Vraag Nook wat je wilt. Je gesprekken verschijnen hier.", "Ask Nook anything. Your conversations will show up here.")}</span><button class="primary" onclick={newNook}>{tr("Nieuwe Nook", "New Nook")}</button></div>
        {/if}
      {/if}
    </div>
    {#if shelf.length}
      <!-- The archive docked at the foot, as the settled sessions are on Agents: it opens upwards. -->
      <div class="shelf">
        {#if showArchived}<div class="shelf-rows">{#each shelf as item (item.id)}{@render row(item, false)}{/each}</div>{/if}
        <button class="shelf-head" aria-expanded={showArchived} onclick={() => (showArchived = !showArchived)}>
          <span>{tr("Archief ({n})", "Archive ({n})", { n: shelf.length })}</span>
          <span class="rule"></span>
          <Ico name={showArchived ? "chevron-down" : "chevron-up"} size={11} stroke={2.2} />
        </button>
      </div>
    {/if}
    {#if picked.size}
      <!-- Several picked (`SelectionBar`): what to do with all of them. -->
      <div class="selection" role="toolbar" aria-label={tr("{n} geselecteerd", "{n} selected", { n: picked.size })}>
        <div class="selection-head">
          <span class="selection-count">{tr("{n} geselecteerd", "{n} selected", { n: picked.size })}</span>
          <button class="link" onclick={() => (picked = allPicked ? new Set() : new Set(list.map((i) => i.id)))}>{allPicked ? tr("Niets selecteren", "Select none") : tr("Selecteer alles", "Select all")}</button>
          <span class="grow"></span>
          <button class="link" onclick={() => (picked = new Set())}>{tr("Klaar", "Done")}</button>
        </div>
        <div class="selection-actions">
          {#if anyUnread}
            <button class="row-button" title={tr("Markeer als gelezen", "Mark as read")} aria-label={tr("Markeer als gelezen", "Mark as read")} disabled={pending} onclick={() => setFlags([...picked], { unread: false })}><Ico name="mail-open" size={14} /></button>
          {:else}
            <button class="row-button" title={tr("Markeer als ongelezen", "Mark as unread")} aria-label={tr("Markeer als ongelezen", "Mark as unread")} disabled={pending} onclick={() => setFlags([...picked], { unread: true })}><Ico name="mail" size={14} /></button>
          {/if}
          {#if !allArchived}
            <button class="row-button" title={allPinned ? tr("Maak los", "Unpin") : tr("Zet vast", "Pin")} aria-label={allPinned ? tr("Maak los", "Unpin") : tr("Zet vast", "Pin")} disabled={pending} onclick={() => setFlags([...picked], { pinned: !allPinned })}><Ico name={allPinned ? "pin-off" : "pin"} size={14} /></button>
          {/if}
          <button class="row-button" title={allArchived ? tr("Haal uit archief", "Unarchive") : tr("Archiveer", "Archive")} aria-label={allArchived ? tr("Haal uit archief", "Unarchive") : tr("Archiveer", "Archive")} disabled={pending || !idle.length} onclick={() => setFlags(idle.map((i) => i.id), { archived: !allArchived })}><Ico name="archive" size={14} /></button>
          <button class="row-button danger" title={tr("Verwijder", "Delete")} aria-label={tr("Verwijder", "Delete")} disabled={pending || !idle.length} onclick={() => confirmDelete(idle.map((i) => i.id))}><Ico name="trash-2" size={14} /></button>
        </div>
      </div>
    {/if}
  </div>
  {/if}
</aside>

{#if hover && !menu && renaming !== hover.item.id}
  {@const item = hover.item}
  {@const card = item.card}
  <!-- What a Nook did, beside its row (`NookHoverCard`). -->
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <div class="hover-card" role="tooltip" style:left="{hover.rect.right + 8}px" style:top="{Math.min(hover.rect.top, window.innerHeight - 320)}px"
    onpointerenter={() => clearTimeout(hoverTimer)} onpointerleave={hoverOut}>
    <div class="hc-title">{item.title}</div>
    {#if card}
      {#if card.tasksTotal}<div class="hc-row"><Ico name="list-checks" size={12} /><span>{tr("{done} van {total} stappen klaar", "{done} of {total} steps completed", { done: card.tasksDone, total: card.tasksTotal })}</span></div>{/if}
      {#if card.task}<div class="hc-row"><Ico name={card.taskActive ? "hourglass" : "check"} size={12} /><span>{card.task}</span></div>{/if}
      {#if card.mailTo !== null}<div class="hc-row"><Ico name="mail" size={12} /><span>{card.mailTo ? tr("Conceptmail aan {to}", "Draft email to {to}", { to: card.mailTo }) : tr("Conceptmail opgesteld", "Draft email prepared")}</span></div>{/if}
      {#if card.chart !== null}<div class="hc-row"><Ico name="chart-column" size={12} /><span>{card.chart || tr("Grafiek gemaakt", "Chart created")}</span></div>{/if}
      {#if card.sources.length}<div class="hc-row"><Ico name="search" size={12} /><span>{tr("Bronnen: {list}", "Sources: {list}", { list: card.sources.join(", ") })}</span></div>{/if}
      {#if card.request}<div class="hc-block"><span class="hc-label">{tr("Vraag", "Request")}</span><span class="hc-text strong">{card.request}</span></div>{/if}
      {#if card.summary}<div class="hc-block"><span class="hc-label">{tr("Inhoud", "Content")}</span><span class="hc-text">{card.summary}</span></div>{/if}
      <div class="hc-row"><Ico name="clock" size={12} /><span>{tr("Gestart {time}", "Started {time}", { time: relativeTime(card.created) })}</span></div>
      {#if item.updated > card.created}<div class="hc-row"><Ico name="rotate-cw" size={12} /><span>{tr("Laatst actief {time}", "Last active {time}", { time: relativeTime(item.updated) })}</span></div>{/if}
      <div class="hc-row"><Ico name="messages-square" size={12} /><span>{card.messages === 1 ? tr("1 bericht", "1 message") : tr("{n} berichten", "{n} messages", { n: card.messages })}</span></div>
      {#if card.scope}<div class="hc-row"><Ico name="list-filter" size={12} /><span>{card.scope}</span></div>{/if}
    {:else if item.preview}
      <div class="hc-text">{item.preview}</div>
    {/if}
  </div>
{/if}

{#if menu}<Menu sections={menuFor(menu.item)} anchor={menu.at} onclose={() => (menu = null)} />{/if}

<style>
  .list { display: flex; flex-direction: column; min-height: 0; background: transparent; }
  /* The head as the Mac's `PanelTabHeader`: tabs on the left, the new-Nook button on the right, 30 px tall. */
  .head { display: flex; align-items: center; gap: var(--space-8); height: 30px; margin: var(--space-8) 0; }
  .grow { flex: 1; min-width: 0; }
  .tabs { display: flex; gap: var(--space-2); }
  .tabs button { all: unset; cursor: pointer; display: inline-flex; align-items: center; gap: var(--space-6); height: 26px; padding: 0 var(--space-12); border-radius: var(--radius-control); font: var(--text-control); color: var(--text3); }
  .tabs button:hover:not(.on) { color: var(--paper); }
  .tabs button.on { color: var(--paper); background: var(--smoke); }
  .tabs button:focus-visible { outline: 2px solid var(--iris); outline-offset: 1px; }
  .count.waiting { color: var(--amber); background: color-mix(in srgb, var(--amber) 16%, transparent); }
  .fresh { width: 6px; height: 6px; border-radius: 50%; background: var(--iris); }
  .count { color: var(--text3); background: var(--smoke); border-radius: var(--radius-control); padding: 2px 6px; font: var(--text-caption); }
  .new-nook { display: grid; place-items: center; width: 28px; height: 28px; padding: 0; border: 0; border-radius: var(--radius-control); background: transparent; color: var(--text2); }
  .new-nook:hover, .new-nook.on { background: var(--smoke); color: var(--paper); }
  .search { display: flex; align-items: center; gap: var(--space-6); height: 30px; margin: 0 0 var(--space-8); padding: 0 var(--space-8); color: var(--text3); background: var(--field); border: 0; border-radius: var(--radius-control); }
  .search:focus-within { box-shadow: inset 0 0 0 1px var(--line2); }
  .search input { min-width: 0; width: 100%; border: 0; background: transparent; padding: 0; font: var(--text-body); box-shadow: none; }
  .search button { padding: 0 4px; }
  .items { flex: 1; min-height: 0; display: flex; flex-direction: column; }
  .scroll { flex: 1; min-height: 0; overflow-y: auto; display: flex; flex-direction: column; gap: var(--space-2); padding: 0 0 var(--space-12); }
  /* `NookSectionLabel`: lined up with the rows' text, 8 pt above a later group. */
  .section-label { margin: 0; padding: 0 var(--space-12) var(--space-2); font: var(--text-label); color: var(--text3); }
  .section-label.gap { padding-top: var(--space-8); }
  /* "For you": a card in the field's colour with a faint line, 4 pt inside. */
  .for-you { display: flex; flex-direction: column; gap: var(--space-2); padding: var(--space-4); margin-bottom: var(--space-6); background: var(--field); border: 1px solid var(--line); border-radius: calc(var(--radius-panel) + var(--space-2)); }
  .for-you-head { display: flex; align-items: center; gap: var(--space-6); padding: var(--space-4) var(--space-12) var(--space-2); font: var(--text-label); color: var(--text3); }
  .item { position: relative; border-radius: var(--radius-card); }
  .item:hover { background: var(--row-hover); }
  .item.active { background: var(--row-selected); }
  .item.picked { background: color-mix(in srgb, var(--iris) 10%, transparent); }
  /* A row as the Mac's: 12 pt in, 8 pt above and below on one line, 10 with the line under it. */
  .conversation { display: flex; flex-direction: column; gap: var(--space-2); width: 100%; min-width: 0; text-align: left; border: 0; background: transparent; padding: calc(var(--space-8) + var(--space-2)) var(--space-12); border-radius: var(--radius-card); }
  .conversation.compact { padding: var(--space-8) var(--space-12); }
  .top { display: flex; align-items: center; gap: var(--space-6); min-width: 0; width: 100%; }
  .title { min-width: 0; font: var(--text-emphasis); color: var(--paper); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .title.receded { font: var(--text-body); color: var(--text2); }
  .title.archived { color: var(--text2); }
  .mark { display: inline-flex; color: var(--text3); flex: none; }
  .check { display: inline-flex; color: var(--iris); flex: none; }
  .slot { flex: none; display: inline-flex; align-items: center; }
  .meta { font: var(--text-caption); color: var(--text3); font-variant-numeric: tabular-nums; }
  .preview { font: var(--text-detail); color: var(--text3); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  /* Pin and archive on hover, in the badge's place, so nothing shifts. */
  .hover-actions { position: absolute; top: var(--space-6); right: var(--space-8); display: none; gap: var(--space-2); }
  .item:hover .hover-actions, .item:focus-within .hover-actions { display: inline-flex; }
  .item:hover .slot, .item:focus-within .slot { visibility: hidden; }
  .row-button { display: inline-flex; align-items: center; justify-content: center; width: 22px; height: 22px; padding: 0; border: 0; border-radius: var(--radius-control); background: transparent; color: var(--text2); }
  .row-button:hover:not(:disabled) { background: var(--smoke); color: var(--paper); }
  .row-button.danger { color: var(--coral); }
  .rename { width: 100%; height: 40px; box-sizing: border-box; padding: 0 var(--space-12); font: var(--text-emphasis); color: var(--paper); background: var(--row-selected); border: 1px solid color-mix(in srgb, var(--iris) 40%, transparent); border-radius: var(--radius-panel); }
  .shelf { flex: none; display: flex; flex-direction: column; gap: var(--space-2); }
  .shelf-rows { max-height: 280px; overflow-y: auto; display: flex; flex-direction: column; gap: var(--space-2); }
  .shelf-head { display: flex; align-items: center; gap: var(--space-8); height: 30px; padding: 0 var(--space-12); border: 0; background: transparent; color: var(--text3); font: var(--text-label); }
  .shelf-head:hover { color: var(--paper); }
  .rule { flex: 1; height: 1px; background: var(--separator); }
  .selection { flex: none; display: flex; flex-direction: column; gap: var(--space-6); margin-top: var(--space-6); padding: var(--space-8); background: var(--graphite); border: 1px solid var(--line2); border-radius: var(--radius-card); }
  .selection-head { display: flex; align-items: center; gap: var(--space-8); }
  .selection-count { font: var(--text-control); color: var(--paper); }
  .selection-actions { display: flex; gap: var(--space-4); }
  .link { padding: 0; border: 0; background: transparent; font: var(--text-label); color: var(--text2); }
  .link:hover { color: var(--paper); }
  .hover-card { position: fixed; z-index: 60; width: 280px; display: flex; flex-direction: column; gap: var(--space-6); padding: var(--space-12); background: var(--menu); border: 1px solid var(--line2); border-radius: var(--radius-panel); box-shadow: var(--shadow-popover); }
  .hc-title { font: var(--text-control); color: var(--paper); }
  .hc-row { display: flex; align-items: flex-start; gap: var(--space-6); font: var(--text-detail); color: var(--text2); }
  .hc-row :global(svg) { margin-top: var(--space-2); color: var(--text3); }
  .hc-block { display: flex; flex-direction: column; gap: var(--space-2); }
  .hc-label { font: var(--text-caption); color: var(--text3); }
  .hc-text { font: var(--text-detail); color: var(--text2); display: -webkit-box; -webkit-line-clamp: 3; line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden; }
  .hc-text.strong { color: var(--paper); -webkit-line-clamp: 2; line-clamp: 2; }
  .note { margin: 0; padding: var(--space-12); font: var(--text-detail); color: var(--text3); }
  .list-empty { display: flex; flex-direction: column; align-items: center; text-align: center; margin: auto 0; padding: var(--space-32) var(--space-12); color: var(--text2); }
  .list-empty p { color: var(--paper); margin: var(--space-12) 0 var(--space-6); font: var(--text-title); }
  .list-empty span { font: var(--text-body); line-height: 1.4; max-width: 200px; }
  .list-empty button { margin-top: var(--space-16); }
  .state { text-align: center; padding: var(--space-16) var(--space-8); color: var(--text2); font: var(--text-detail); }
  button:focus-visible { outline: 2px solid var(--iris); outline-offset: 1px; }
</style>
