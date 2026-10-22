<script lang="ts">
  import Icon from "./Icon.svelte";
  import { api } from "../lib/api";
  import { nook, relativeTime } from "../lib/state.svelte";
  import type { ConversationSummary } from "../lib/types";

  let query = $state("");
  let results = $state<ConversationSummary[] | null>(null);
  let menu = $state<string | null>(null);

  $effect(() => {
    const q = query.trim();
    if (!q) {
      results = null;
      return;
    }
    // Waits for a pause in typing, and drops an answer for an older query so it cannot replace a newer one.
    let stale = false;
    const timer = setTimeout(() => {
      api
        .searchNooks(q)
        .then((r) => {
          if (!stale) results = r;
        })
        .catch(() => {});
    }, 150);
    return () => {
      stale = true;
      clearTimeout(timer);
    };
  });

  const list = $derived(results ?? nook.nooks.filter((n) => n.preview || n.id === nook.activeId));
</script>

<svelte:window onkeydown={(e) => { if (e.key === "Escape") menu = null; }} />

<aside class="list" aria-label="Conversations">
  <header><span>Conversations</span><span class="count">{list.length}</span></header>
  <button class="new-nook" onclick={() => nook.newNook()}><Icon name="plus" size={16} /><span>New Nook</span><kbd>Ctrl N</kbd></button>
  <label class="search"><Icon name="search" size={15} /><input aria-label="Search conversations" placeholder="Search conversations" bind:value={query} /></label>
  <div class="section-label">{query.trim() ? "SEARCH RESULTS" : "YOUR NOOKS"}</div>
  <div class="items">
    {#each list as item (item.id)}
      <div
        class="item"
        class:active={item.id === nook.activeId}
        role="button"
        tabindex="0"
        onclick={() => nook.select(item.id)}
        onkeydown={(e) => { if (e.target === e.currentTarget && (e.key === "Enter" || e.key === " ")) { e.preventDefault(); nook.select(item.id); } }}
        oncontextmenu={(e) => { e.preventDefault(); menu = menu === item.id ? null : item.id; }}
      >
        <div class="line">
          <span class="dot {item.status}"></span>
          <span class="title" title={item.title}>{item.pinned ? "📌 " : ""}{item.title}</span>
          <span class="time faint">{relativeTime(item.updated)}</span>
          <button class="ghost menu-trigger" aria-label={`Actions for ${item.title}`} aria-expanded={menu === item.id} onclick={(e) => { e.stopPropagation(); menu = menu === item.id ? null : item.id; }}>...</button>
        </div>
        {#if item.preview}<div class="preview faint">{item.preview}</div>{/if}
        {#if menu === item.id}
          <div class="menu">
            <button class="ghost" onclick={(e) => { e.stopPropagation(); api.setNookFlags(item.id, { pinned: !item.pinned }); menu = null; }}>{item.pinned ? "Unpin" : "Pin"}</button>
            <button class="ghost" onclick={(e) => { e.stopPropagation(); api.setNookFlags(item.id, { archived: !item.archived }); menu = null; }}>{item.archived ? "Restore" : "Archive"}</button>
            <button class="ghost danger" onclick={(e) => { e.stopPropagation(); api.deleteNook(item.id); menu = null; }}>Delete</button>
          </div>
        {/if}
      </div>
    {:else}
      <div class="list-empty"><Icon name="chat" size={24} /><p>{query.trim() ? "No conversations found" : "A little room to think"}</p><span>{query.trim() ? "Try a different search." : "Start a Nook. Your conversations will appear here."}</span></div>
    {/each}
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
  .section-label { padding: 24px 22px 10px; font-size: 9px; color: var(--text3); letter-spacing: 1.4px; font-weight: 600; }
  .items { overflow-y: auto; flex: 1; padding: 0 10px 14px; }
  .item { padding: 10px; border: 1px solid transparent; border-radius: var(--radius-control); cursor: pointer; margin-bottom: 3px; }
  .item:hover { background: var(--row-hover); }
  .item.active { background: var(--smoke); border-color: var(--line2); }
  .line { display: flex; align-items: center; gap: 8px; min-height: 22px; }
  .title { flex: 1; min-width: 0; font-size: 12px; font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .time { font-size: 10px; white-space: nowrap; }
  .preview { font-size: 11px; margin: 4px 0 0 15px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .menu-trigger { padding: 0; width: 22px; height: 22px; flex-shrink: 0; font-weight: 700; }
  .menu { display: flex; flex-wrap: wrap; gap: 4px; margin-top: 10px; border-top: 1px solid var(--line2); padding-top: 6px; }
  .menu button { font-size: 11px; padding: 4px 6px; }
  .dot.idle { background: var(--text3); width: 5px; height: 5px; margin: 1px; }
  .list-empty { display: flex; flex-direction: column; align-items: center; text-align: center; padding: 32px 12px; color: var(--text3); }
  .list-empty p { color: var(--text2); margin: 12px 0 6px; font-size: 12px; }
  .list-empty span { font-size: 11px; line-height: 1.6; max-width: 180px; }
</style>
