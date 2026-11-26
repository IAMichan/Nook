<script lang="ts">
  // Every emoji to choose from, as a chat app's emoji picker (the Mac's `EmojiBrowser`): a search on top (English names
  // and Nook's own multilingual names), a tab per group (smileys, people, animals…) that jumps there, and the emoji in
  // a 9-column grid under sticky group headers. The ones you use most come first under "Frequently Used" (`emojiUsage`)
  // and lead search results. Used by the reaction picker's "+" under a chat bubble and by the composer's smiley.
  import { tr } from "../../lib/i18n.svelte";
  import {
    emojiFor,
    emojiGroupLabel,
    emojiGroups,
    searchEmoji,
    type EmojiGroupId,
    type EmojiItem,
  } from "../../lib/emoji-catalog";
  import { emojiUsage } from "../../lib/emoji-usage";
  import Ico from "./Ico.svelte";
  import SearchField from "./SearchField.svelte";
  import { tip } from "./tip";

  type TabId = EmojiGroupId | "recent";

  let { chosen = null, onchoose }: {
    /** The emoji already chosen (your reaction), marked in the grid. */
    chosen?: string | null;
    onchoose: (character: string) => void;
  } = $props();

  const groups = emojiGroups();
  // Snapshot frequent emoji when mounted so picking one while open does not shift items under the pointer.
  const recent: readonly EmojiItem[] = emojiUsage.ranked().map(emojiFor);

  let query = $state("");
  let activeGroup = $state<TabId>(recent.length > 0 ? "recent" : (groups[0]?.id ?? "smileys"));
  let scrollEl = $state<HTMLDivElement>();

  const tabs = $derived<{ id: TabId; icon: string; label: string }[]>([
    ...(recent.length > 0 ? [{ id: "recent" as const, icon: "clock", label: emojiGroupLabel("recent") }] : []),
    ...groups.map((g) => ({ id: g.id as TabId, icon: g.icon, label: emojiGroupLabel(g.id) })),
  ]);

  const results = $derived(
    query.trim() ? emojiUsage.usedFirst(searchEmoji(query), (e) => e.character) : [],
  );

  function pick(character: string) {
    if (character !== chosen) emojiUsage.record(character);
    onchoose(character);
  }

  function jumpTo(id: TabId) {
    activeGroup = id;
    const section = scrollEl?.querySelector<HTMLElement>(`[data-emoji-group="${id}"]`);
    section?.scrollIntoView({ block: "start", behavior: "smooth" });
  }

  function onScroll() {
    if (!scrollEl || query.trim()) return;
    const top = scrollEl.scrollTop + 8;
    const sections = scrollEl.querySelectorAll<HTMLElement>("[data-emoji-group]");
    let current: TabId = activeGroup;
    for (const sec of sections) {
      if (sec.offsetTop <= top) {
        const id = sec.dataset.emojiGroup as TabId | undefined;
        if (id) current = id;
      } else {
        break;
      }
    }
    if (current !== activeGroup) activeGroup = current;
  }
</script>

<div class="browser" role="region" aria-label={tr("Emoji", "Emoji")}>
  <SearchField
    bind:value={query}
    placeholder={tr("Zoek een emoji", "Search emoji")}
    autofocus
    onenter={() => { if (results[0]) pick(results[0].character); }}
  />
  {#if !query.trim()}
    <div class="tabs" role="tablist" aria-label={tr("Emoji", "Emoji")}>
      {#each tabs as tab (tab.id)}
        <button
          type="button"
          role="tab"
          class="tab"
          class:on={tab.id === activeGroup}
          aria-selected={tab.id === activeGroup}
          aria-label={tab.label}
          use:tip={tab.label}
          onclick={() => jumpTo(tab.id)}
        >
          <Ico name={tab.icon} size={13} stroke={2.1} />
        </button>
      {/each}
    </div>
  {/if}
  <div class="scroll" bind:this={scrollEl} onscroll={onScroll}>
    {#if !query.trim()}
      {#if recent.length > 0}
        <section class="group" data-emoji-group="recent">
          <div class="group-head">{emojiGroupLabel("recent")}</div>
          <div class="grid" role="listbox" aria-label={emojiGroupLabel("recent")}>
            {#each recent as item (item.character)}
              <button
                type="button"
                role="option"
                class="cell"
                class:chosen={item.character === chosen}
                aria-selected={item.character === chosen}
                aria-label={item.name}
                onclick={() => pick(item.character)}
              >{item.character}</button>
            {/each}
          </div>
        </section>
      {/if}
      {#each groups as group (group.id)}
        <section class="group" data-emoji-group={group.id}>
          <div class="group-head">{emojiGroupLabel(group.id)}</div>
          <div class="grid" role="listbox" aria-label={emojiGroupLabel(group.id)}>
            {#each group.emoji as item (item.character)}
              <button
                type="button"
                role="option"
                class="cell"
                class:chosen={item.character === chosen}
                aria-selected={item.character === chosen}
                aria-label={item.name}
                onclick={() => pick(item.character)}
              >{item.character}</button>
            {/each}
          </div>
        </section>
      {/each}
    {:else if results.length === 0}
      <p class="empty">{tr("Geen emoji voor “{query}”", "No emoji for “{query}”", { query: query.trim() })}</p>
    {:else}
      <div class="grid" role="listbox" aria-label={tr("Zoek een emoji", "Search emoji")}>
        {#each results as item (item.character)}
          <button
            type="button"
            role="option"
            class="cell"
            class:chosen={item.character === chosen}
            aria-selected={item.character === chosen}
            aria-label={item.name}
            onclick={() => pick(item.character)}
          >{item.character}</button>
        {/each}
      </div>
    {/if}
  </div>
</div>

<style>
  .browser {
    display: flex;
    flex-direction: column;
    gap: var(--space-8);
    width: 318px;
    max-width: 100%;
    padding: var(--space-8);
    box-sizing: border-box;
  }
  .tabs {
    display: flex;
    align-items: center;
    gap: var(--space-2);
  }
  .tab {
    display: grid;
    place-items: center;
    width: 28px;
    height: 26px;
    flex: 1;
    min-width: 0;
    padding: 0;
    margin: 0;
    border: 0;
    border-radius: var(--radius-chip);
    background: transparent;
    color: var(--text3);
  }
  .tab:hover { background: var(--smoke); color: var(--text-strong); }
  .tab.on { background: color-mix(in srgb, var(--paper) 10%, transparent); color: var(--paper); }
  .scroll {
    position: relative;
    height: 260px;
    overflow-y: auto;
    overflow-x: hidden;
    padding-right: var(--space-2);
  }
  .group {
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
    margin-bottom: var(--space-8);
    content-visibility: auto;
    contain-intrinsic-size: auto 180px;
  }
  .group:last-child { margin-bottom: 0; }
  .group-head {
    position: sticky;
    top: 0;
    z-index: 1;
    padding: var(--space-2) 0;
    background: var(--menu);
    font: var(--text-caption);
    color: var(--text3);
  }
  .grid {
    display: grid;
    grid-template-columns: repeat(9, 32px);
    gap: var(--space-2);
  }
  .cell {
    display: grid;
    place-items: center;
    width: 32px;
    height: 32px;
    padding: 0;
    margin: 0;
    border: 0;
    border-radius: var(--radius-control);
    background: transparent;
    font: var(--text-display);
    font-weight: 400;
    line-height: 1;
  }
  .cell:hover { background: var(--smoke); }
  .cell.chosen { background: color-mix(in srgb, var(--mint) 20%, transparent); }
  .empty {
    margin: 0;
    padding: var(--space-24) var(--space-8);
    text-align: center;
    font: var(--text-detail);
    color: var(--text2);
  }
</style>
