<script lang="ts">
  import { onMount, tick } from "svelte";
  import Icon from "./Icon.svelte";
  import { api } from "../lib/api";
  import { nook } from "../lib/state.svelte";
  import { toast } from "../lib/toast.svelte";
  import { conversationGroups, recoverDeletedConversation } from "../lib/conversation-list";
  import type { ConversationSummary } from "../lib/types";

  type SearchState = { kind: "idle" } | { kind: "loading" } | { kind: "error" } | { kind: "ready"; items: ConversationSummary[] };
  let query = $state("");
  let search = $state<SearchState>({ kind: "idle" });
  let retry = $state(0);
  let loading = $state(true);
  let listError = $state(false);
  let menu = $state<string | null>(null);
  let confirming = $state<string | null>(null);
  let pending = $state(false);
  let itemsElement: HTMLDivElement;
  const deleted = new Set<string>();

  const groups = $derived(query.trim()
    ? search.kind === "ready" ? [{ title: "Search results", items: search.items }] : []
    : conversationGroups(nook.nooks, nook.activeId));
  const list = $derived(groups.flatMap((group) => group.items));

  onMount(() => { refresh(); });
  async function refresh() {
    loading = true;
    listError = false;
    try { await nook.refreshList(); }
    catch { listError = true; }
    finally { loading = false; }
  }

  $effect(() => {
    const q = query.trim();
    retry;
    menu = null;
    confirming = null;
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

  // An already-running store event may finish loading the removed ID after deletion.
  $effect(() => {
    if (nook.activeId && deleted.has(nook.activeId)) {
      nook.activeId = null;
      nook.active = null;
    }
  });

  async function select(id: string) {
    menu = null;
    confirming = null;
    try { await nook.select(id); }
    catch (e) { toast.error("Could not open conversation", e); }
  }

  async function newNook() {
    try { await nook.newNook(); }
    catch (e) { toast.error("Could not create Nook", e); }
  }

  async function mutate(item: ConversationSummary, action: "pin" | "archive" | "delete") {
    if (pending) return;
    pending = true;
    let changed = false;
    try {
      if (action === "delete") {
        await api.deleteNook(item.id);
        deleted.add(item.id);
        changed = true;
        await recoverDeletedConversation(nook, item.id);
      } else {
        await api.setNookFlags(item.id, action === "pin" ? { pinned: !item.pinned } : { archived: !item.archived });
        changed = true;
        await nook.refreshList();
      }
      menu = null;
      confirming = null;
      retry++;
      await tick();
      const target = itemsElement.querySelector<HTMLButtonElement>(".conversation[aria-current='true']") ?? itemsElement.querySelector<HTMLButtonElement>(".conversation");
      target?.focus();
    } catch (e) {
      toast.error(changed ? "Conversation changed, but could not refresh the list" : `Could not ${action === "pin" ? item.pinned ? "unpin" : "pin" : action} conversation`, e);
      if (changed) { menu = null; confirming = null; retry++; }
    } finally { pending = false; }
  }

  function focusRow(index: number) {
    const rows = itemsElement.querySelectorAll<HTMLButtonElement>(".conversation");
    rows[index]?.focus();
  }

  function rowKeys(e: KeyboardEvent, index: number, id: string) {
    if (e.key === "ArrowDown" || e.key === "ArrowUp" || e.key === "Home" || e.key === "End") {
      e.preventDefault();
      focusRow(e.key === "Home" ? 0 : e.key === "End" ? list.length - 1 : Math.max(0, Math.min(list.length - 1, index + (e.key === "ArrowDown" ? 1 : -1))));
    } else if (e.key === "F10" && e.shiftKey) {
      e.preventDefault();
      menu = id;
      confirming = null;
      tick().then(() => itemsElement.querySelector<HTMLButtonElement>(".actions button")?.focus());
    }
  }

  function closeActions(e: KeyboardEvent) {
    if (e.key !== "Escape" || !menu || pending) return;
    e.preventDefault();
    const index = list.findIndex((item) => item.id === menu);
    menu = null;
    confirming = null;
    tick().then(() => focusRow(index));
  }
</script>

<svelte:window onkeydown={closeActions} />

<aside class="list" aria-label="Conversations">
  <header><span>Conversations</span><span class="count">{list.length}</span></header>
  <button class="new-nook" onclick={newNook}><Icon name="plus" size={16} /><span>New Nook</span><kbd>Ctrl N</kbd></button>
  <label class="search"><Icon name="search" size={15} /><input aria-label="Search conversations" placeholder="Search conversations" bind:value={query} onkeydown={(e) => { if (e.key === "ArrowDown" && list.length) { e.preventDefault(); focusRow(0); } }} />{#if query}<button class="ghost" aria-label="Clear search" onclick={() => query = ""}>×</button>{/if}</label>
  <div class="items" bind:this={itemsElement} aria-busy={query.trim() ? search.kind === "loading" : loading}>
    {#if query.trim() && search.kind === "loading" || !query.trim() && loading && !list.length}
      <p class="state" role="status">{query.trim() ? "Searching conversations…" : "Loading conversations…"}</p>
    {:else if query.trim() && search.kind === "error" || !query.trim() && listError}
      <div class="state" role="alert"><p>{query.trim() ? "Could not search conversations." : "Could not load conversations."}</p><button class="ghost" onclick={() => query.trim() ? retry++ : refresh()}>Try again</button></div>
    {/if}
    {#each groups as group}
      {#if group.items.length}<h2 class="section-label">{group.title}<span>{group.items.length}</span></h2>{/if}
      {#each group.items as item (item.id)}
        <div class="item" class:active={item.id === nook.activeId}>
          <div class="line">
            <button class="conversation" aria-current={item.id === nook.activeId ? "true" : undefined} onclick={() => select(item.id)} onkeydown={(e) => rowKeys(e, list.findIndex((row) => row.id === item.id), item.id)} oncontextmenu={(e) => { e.preventDefault(); menu = item.id; confirming = null; }}>
              <span class="heading"><span class="dot {item.status}" title={item.status}></span><span class="title" title={item.title}>{item.title}</span></span>
              {#if item.preview}<span class="preview faint">{item.preview}</span>{/if}
              <span class="meta">{item.archived ? "Archived · " : ""}{new Date(item.updated).toLocaleDateString("en", { month: "short", day: "numeric" })}</span>
            </button>
            <button class="ghost menu-trigger" aria-label={`Actions for ${item.title}`} title="Conversation actions (Shift+F10)" aria-expanded={menu === item.id} disabled={pending} onclick={() => { menu = menu === item.id ? null : item.id; confirming = null; }}>···</button>
          </div>
          {#if menu === item.id}
            <div class="actions" role="group" aria-label={`Actions for ${item.title}`}>
              {#if confirming === item.id}
                <p>Delete this conversation? This cannot be undone.</p>
                <button class="ghost" disabled={pending} onclick={() => confirming = null}>Cancel</button>
                <button class="danger" disabled={pending} onclick={() => mutate(item, "delete")}>{pending ? "Deleting…" : "Delete conversation"}</button>
              {:else}
                <button class="ghost" disabled={pending} onclick={() => mutate(item, "pin")}>{item.pinned ? "Unpin" : "Pin"}</button>
                <button class="ghost" disabled={pending} onclick={() => mutate(item, "archive")}>{item.archived ? "Restore" : "Archive"}</button>
                <button class="ghost danger" disabled={pending} onclick={() => { confirming = item.id; tick().then(() => itemsElement.querySelector<HTMLButtonElement>(".actions button")?.focus()); }}>Delete…</button>
              {/if}
            </div>
          {/if}
        </div>
      {/each}
    {/each}
    {#if !list.length && (query.trim() ? search.kind === "ready" : !loading && !listError)}
      <div class="list-empty"><Icon name="chat" size={24} /><p>{query.trim() ? "No conversations found" : "A little room to think"}</p><span>{query.trim() ? "Search titles and messages, including archived Nooks." : "Start a Nook. Your conversations will appear here."}</span>{#if query.trim()}<button class="ghost" onclick={() => query = ""}>Clear search</button>{/if}</div>
    {/if}
  </div>
</aside>

<style>
  .list { display: flex; flex-direction: column; min-height: 0; border-right: 1px solid var(--line); background: var(--graphite); }
  header { display: flex; align-items: center; gap: 8px; min-height: 64px; padding: 16px 20px; font-weight: 600; }
  .count { color: var(--text3); background: var(--smoke); border-radius: var(--radius-control); padding: 2px 6px; font-size: 10px; font-weight: 500; }
  .new-nook { margin: 4px 14px 16px; display: flex; align-items: center; gap: 8px; min-height: 38px; background: var(--smoke); box-shadow: var(--shadow-control); }
  .new-nook kbd { margin-left: auto; color: var(--text3); font-size: 10px; }
  .search { display: flex; align-items: center; gap: 8px; margin: 0 14px; padding: 0 10px; color: var(--text3); background: var(--field); border: 1px solid var(--line2); border-radius: var(--radius-control); }
  .search:focus-within { border-color: var(--iris); }
  .search input { min-width: 0; width: 100%; border: 0; background: transparent; padding: 9px 0; font-size: 12px; box-shadow: none; }
  .search button { padding: 0 4px; }
  .section-label { display: flex; justify-content: space-between; margin: 0; padding: 20px 12px 10px; font-size: 10px; color: var(--text3); letter-spacing: 1px; font-weight: 600; }
  .items { overflow-y: auto; flex: 1; padding: 0 10px 14px; }
  .item { border: 1px solid transparent; border-radius: var(--radius-control); margin-bottom: 3px; }
  .item:hover { background: var(--row-hover); }
  .item.active { background: var(--smoke); border-color: var(--line2); }
  .line { display: flex; align-items: flex-start; gap: 4px; }
  .conversation { min-width: 0; flex: 1; text-align: left; border: 0; background: transparent; padding: 10px; border-radius: var(--radius-control); }
  .heading { display: flex; align-items: center; gap: 8px; }
  .title { min-width: 0; font-size: 12px; font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .preview { display: block; font-size: 11px; margin: 4px 0 0 15px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .meta { display: block; margin: 5px 0 0 15px; font-size: 10px; color: var(--text3); }
  .menu-trigger { padding: 0; width: 28px; min-height: 28px; margin: 6px 4px 0 0; flex-shrink: 0; font-weight: 700; }
  .actions { display: flex; flex-wrap: wrap; gap: 4px; margin: 0 10px 10px; border-top: 1px solid var(--line2); padding-top: 6px; }
  .actions p { width: 100%; margin: 4px 0; font-size: 11px; color: var(--text2); line-height: 1.6; }
  .actions button { font-size: 11px; padding: 5px 7px; border-radius: var(--radius-control); }
  .dot.idle { background: var(--text3); width: 5px; height: 5px; margin: 1px; }
  .list-empty { display: flex; flex-direction: column; align-items: center; text-align: center; padding: 32px 12px; color: var(--text3); }
  .list-empty p { color: var(--text2); margin: 12px 0 6px; font-size: 12px; }
  .list-empty span { font-size: 11px; line-height: 1.6; max-width: 180px; }
  .list-empty button { margin-top: 12px; }
  .state { text-align: center; padding: 16px 10px; color: var(--text2); font-size: 12px; }
  button:focus-visible { outline: 2px solid var(--iris); outline-offset: 1px; }
</style>
