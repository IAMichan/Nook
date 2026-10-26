<script lang="ts">
  // The chat history in the bar, as on the Mac: a new-Nook button, a search, pinned conversations first and then the
  // recent ones, each row with its status, how long ago and the last answer, and the archive at the foot. Pin, copy,
  // archive and delete show on hover; delete asks first.
  import { onMount } from "svelte";
  import Icon from "../components/Icon.svelte";
  import { api } from "../lib/api";
  import { conversationGroups } from "../lib/conversation-list";
  import { conversationMarkdown } from "../lib/conversation-export";
  import { tr } from "../lib/i18n.svelte";
  import { nook, relativeTime } from "../lib/state.svelte";
  import { toast } from "../lib/toast.svelte";
  import type { ConversationSummary } from "../lib/types";

  let query = $state("");
  let found = $state<ConversationSummary[] | null>(null);
  let archived = $state<ConversationSummary[]>([]);
  let showArchived = $state(false);
  let confirming = $state<string | null>(null);

  const groups = $derived(conversationGroups(nook.nooks, nook.activeId));

  onMount(() => {
    nook.refreshList().catch(() => {});
    loadArchived();
  });

  async function loadArchived() {
    archived = await api.nooks(true).catch(() => []);
  }

  $effect(() => {
    const q = query.trim();
    if (!q) {
      found = null;
      return;
    }
    let stale = false;
    const timer = setTimeout(async () => {
      const items = await api.searchNooks(q).catch(() => []);
      if (!stale) found = items;
    }, 150);
    return () => {
      stale = true;
      clearTimeout(timer);
    };
  });

  async function open(id: string) {
    confirming = null;
    try {
      await nook.select(id);
    } catch (e) {
      toast.error(tr("Kon het gesprek niet openen", "Could not open conversation"), e);
    }
  }

  async function start() {
    try {
      await nook.newNook();
    } catch (e) {
      toast.error(tr("Kon geen nieuwe Nook maken", "Could not create Nook"), e);
    }
  }

  async function reload() {
    await nook.refreshList();
    await loadArchived();
    if (query.trim()) found = await api.searchNooks(query.trim()).catch(() => found);
  }

  async function flag(item: ConversationSummary, flags: { pinned?: boolean; archived?: boolean }) {
    try {
      await api.setNookFlags(item.id, flags);
      await reload();
    } catch (e) {
      toast.error(tr("Kon het gesprek niet aanpassen", "Could not change conversation"), e);
    }
  }

  async function remove(item: ConversationSummary) {
    try {
      await api.deleteNook(item.id);
      confirming = null;
      if (nook.activeId === item.id) {
        nook.activeId = null;
        nook.active = null;
      }
      await reload();
      if (!nook.activeId) {
        const next = nook.nooks.find((n) => n.id !== item.id);
        if (next) await nook.select(next.id);
      }
    } catch (e) {
      toast.error(tr("Kon het gesprek niet verwijderen", "Could not delete conversation"), e);
    }
  }

  async function copy(item: ConversationSummary) {
    const conversation = await api.nook(item.id);
    if (!conversation) return;
    try {
      await navigator.clipboard.writeText(conversationMarkdown(conversation));
    } catch (e) {
      toast.error(tr("Kopiëren mislukt", "Could not copy"), e);
    }
  }
</script>

{#snippet row(item: ConversationSummary)}
  <div class="item" class:active={item.id === nook.activeId}>
    {#if confirming === item.id}
      <div class="confirm">
        <span>{tr("Dit gesprek verwijderen?", "Delete this conversation?")}</span>
        <button class="ghost" onclick={() => (confirming = null)}>{tr("Annuleren", "Cancel")}</button>
        <button class="danger" onclick={() => remove(item)}>{tr("Verwijderen", "Delete")}</button>
      </div>
    {:else}
      <button class="conversation" onclick={() => open(item.id)} aria-current={item.id === nook.activeId ? "true" : undefined}>
        <span class="heading">
          <span class="dot {item.status}"></span>
          <span class="title">{item.title}</span>
          <span class="when">{relativeTime(item.updated)}</span>
        </span>
        {#if item.preview}<span class="preview faint">{item.preview}</span>{/if}
      </button>
      <span class="actions">
        {#if !item.archived}
          <button class="ghost" title={item.pinned ? tr("Losmaken", "Unpin") : tr("Vastzetten", "Pin")} aria-label={item.pinned ? tr("Losmaken", "Unpin") : tr("Vastzetten", "Pin")} onclick={() => flag(item, { pinned: !item.pinned })}>{item.pinned ? "★" : "☆"}</button>
        {/if}
        <button class="ghost" title={tr("Kopieer als Markdown", "Copy as Markdown")} aria-label={tr("Kopieer als Markdown", "Copy as Markdown")} onclick={() => copy(item)}>⧉</button>
        <button class="ghost" disabled={item.status === "working"} title={item.archived ? tr("Terugzetten", "Restore") : tr("Archiveren", "Archive")} aria-label={item.archived ? tr("Terugzetten", "Restore") : tr("Archiveren", "Archive")} onclick={() => flag(item, { archived: !item.archived })}>{item.archived ? "↥" : "▣"}</button>
        <button class="ghost" disabled={item.status === "working"} title={tr("Verwijderen", "Delete")} aria-label={tr("Verwijderen", "Delete")} onclick={() => (confirming = item.id)}>✕</button>
      </span>
    {/if}
  </div>
{/snippet}

<div class="history">
  <header>
    <span>{tr("Gesprekken", "Chats")}</span>
    <button class="ghost new" title={tr("Nieuwe Nook", "New Nook")} aria-label={tr("Nieuwe Nook", "New Nook")} onclick={start}><Icon name="plus" size={14} /></button>
  </header>
  <label class="search">
    <Icon name="search" size={13} />
    <input aria-label={tr("Gesprekken doorzoeken", "Search chats")} placeholder={tr("Zoeken", "Search")} bind:value={query} />
    {#if query}<button class="ghost" aria-label={tr("Zoekopdracht wissen", "Clear search")} onclick={() => (query = "")}>×</button>{/if}
  </label>

  <div class="items">
    {#if found}
      {#each found as item (item.id)}{@render row(item)}{:else}<p class="faint empty">{tr("Geen gesprekken gevonden", "No chats found")}</p>{/each}
    {:else}
      {#each groups as group (group.title)}
        <h5>{group.title === "Pinned" ? tr("VASTGEZET", "PINNED") : tr("RECENT", "RECENT")}</h5>
        {#each group.items as item (item.id)}{@render row(item)}{/each}
      {:else}
        <p class="faint empty">{tr("Nog geen gesprekken. Begin met een Nook.", "No chats yet. Start a Nook.")}</p>
      {/each}
    {/if}
  </div>

  {#if !found && archived.length}
    <div class="shelf">
      {#if showArchived}
        <div class="archived">{#each archived as item (item.id)}{@render row(item)}{/each}</div>
      {/if}
      <button class="shelf-toggle faint" onclick={() => (showArchived = !showArchived)}>
        {tr(`Gearchiveerd (${archived.length})`, `Archived (${archived.length})`)} <span class:open={showArchived}>⌄</span>
      </button>
    </div>
  {/if}
</div>

<style>
  .history { display: flex; flex-direction: column; height: 100%; min-height: 0; }
  header { display: flex; align-items: center; justify-content: space-between; padding: 2px 8px 6px 12px; font-size: 12px; font-weight: 600; }
  .new { width: 24px; height: 24px; padding: 0; display: grid; place-items: center; }
  .search { display: flex; align-items: center; gap: 6px; margin: 0 8px 6px; padding: 0 8px; color: var(--text3); background: var(--field); border: 1px solid var(--line2); border-radius: var(--radius-control); }
  .search:focus-within { border-color: var(--iris); }
  .search input { min-width: 0; width: 100%; border: 0; background: transparent; padding: 6px 0; font-size: 12px; box-shadow: none; }
  .search button { padding: 0 4px; }
  .items { flex: 1; min-height: 0; overflow-y: auto; padding: 0 6px 6px; }
  h5 { margin: 8px 6px 4px; font-size: 9px; letter-spacing: 0.08em; color: var(--text3); font-weight: 600; }
  .empty { margin: 16px 8px; font-size: 11px; line-height: 1.5; text-align: center; }
  .item { position: relative; border: 1px solid transparent; border-radius: var(--radius-control); margin-bottom: 2px; }
  .item:hover { background: var(--row-hover); }
  .item.active { background: var(--smoke); border-color: var(--line2); }
  .conversation { display: block; width: 100%; text-align: left; border: 0; background: transparent; padding: 7px 8px; border-radius: var(--radius-control); }
  .heading { display: flex; align-items: center; gap: 6px; }
  .title { min-width: 0; flex: 1; font-size: 12px; font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .when { flex: none; font-size: 10px; color: var(--text3); }
  .preview { display: block; margin: 3px 0 0 13px; font-size: 11px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .dot.idle { background: var(--text3); width: 5px; height: 5px; margin: 1px; }
  /* Pin, copy, archive and delete cover the time on hover, so nothing shifts. */
  .actions { position: absolute; top: 3px; right: 3px; display: none; padding-left: 8px; background: var(--row-hover); border-radius: var(--radius-control); }
  .item:hover .actions, .item:focus-within .actions { display: flex; }
  .actions button { width: 22px; height: 22px; padding: 0; font-size: 11px; }
  .confirm { display: flex; flex-wrap: wrap; align-items: center; gap: 4px; padding: 7px 8px; font-size: 11px; }
  .confirm span { width: 100%; color: var(--text2); }
  .confirm button { font-size: 11px; padding: 4px 8px; }
  .shelf { border-top: 1px solid var(--line); }
  .archived { max-height: 160px; overflow-y: auto; padding: 4px 6px 0; }
  .shelf-toggle { width: 100%; display: flex; justify-content: space-between; align-items: center; padding: 8px 12px; font-size: 10px; letter-spacing: 0.04em; background: transparent; border: 0; }
  .shelf-toggle span { transition: transform 0.15s; transform: rotate(180deg); }
  .shelf-toggle span.open { transform: rotate(0); }
  button:focus-visible { outline: 2px solid var(--iris); outline-offset: 1px; }
</style>
