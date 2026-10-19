<script lang="ts">
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
    api.searchNooks(q).then((r) => (results = r));
  });

  const list = $derived(results ?? nook.nooks.filter((n) => n.preview || n.id === nook.activeId));
</script>

<aside class="list">
  <div class="top">
    <input placeholder="Zoek in Nooks" bind:value={query} />
    <button class="ghost" title="Nieuwe Nook (Ctrl+N)" onclick={() => nook.newNook()}>＋</button>
  </div>
  <div class="items">
    {#each list as item (item.id)}
      <div
        class="item"
        class:active={item.id === nook.activeId}
        role="button"
        tabindex="0"
        onclick={() => nook.select(item.id)}
        onkeydown={(e) => e.key === "Enter" && nook.select(item.id)}
        oncontextmenu={(e) => { e.preventDefault(); menu = menu === item.id ? null : item.id; }}
      >
        <div class="line">
          <span class="dot {item.status}"></span>
          <span class="title">{item.pinned ? "📌 " : ""}{item.title}</span>
          <span class="time faint">{relativeTime(item.updated)}</span>
        </div>
        {#if item.preview}<div class="preview faint">{item.preview}</div>{/if}
        {#if menu === item.id}
          <div class="menu">
            <button class="ghost" onclick={(e) => { e.stopPropagation(); api.setNookFlags(item.id, { pinned: !item.pinned }); menu = null; }}>{item.pinned ? "Losmaken" : "Vastzetten"}</button>
            <button class="ghost" onclick={(e) => { e.stopPropagation(); api.setNookFlags(item.id, { archived: !item.archived }); menu = null; }}>{item.archived ? "Terugzetten" : "Archiveren"}</button>
            <button class="ghost danger" onclick={(e) => { e.stopPropagation(); api.deleteNook(item.id); menu = null; }}>Weghalen</button>
          </div>
        {/if}
      </div>
    {:else}
      <p class="faint pad">Nog geen Nooks.</p>
    {/each}
  </div>
</aside>

<style>
  .list { display: flex; flex-direction: column; min-height: 0; border-right: 1px solid var(--line); background: var(--graphite); }
  .top { display: flex; gap: 6px; padding: 10px; }
  .top input { flex: 1; min-width: 0; }
  .items { overflow-y: auto; flex: 1; padding: 0 6px 10px; }
  .item { padding: 8px; border-radius: 10px; cursor: pointer; }
  .item:hover { background: var(--smoke); }
  .item.active { background: var(--smoke); }
  .line { display: flex; align-items: center; gap: 8px; }
  .title { flex: 1; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .time { font-size: 11px; }
  .preview { font-size: 12px; margin: 3px 0 0 15px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .menu { display: flex; gap: 4px; margin-top: 6px; }
  .menu button { font-size: 11px; padding: 3px 8px; }
  .dot.idle { background: var(--line2); }
  .pad { padding: 8px; }
</style>
