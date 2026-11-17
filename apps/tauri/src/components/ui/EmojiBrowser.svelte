<script lang="ts">
  // Every emoji to choose from (`EmojiBrowser`), as a chat app's emoji picker: a search on top (English names, and
  // Nook's own names, Dutch ones too), a tab per group that jumps there, and the emoji in a grid under the name of their
  // group. The ones you use most come first under "Frequently used" (`EmojiUsage`) and lead a search's results; the one
  // already chosen is marked. Behind the "+" of a reaction picker and a composer's smiley, for every chat integration;
  // never build an emoji grid by hand.
  import { tr } from "../../lib/i18n.svelte";
  import { EmojiUsage, emojiFor, emojiGroups, searchEmoji, type Emoji } from "../../lib/emoji";
  import SearchField from "./SearchField.svelte";
  import Ico from "./Ico.svelte";
  import { tip } from "./tip";

  let { chosen = null, onchoose }: {
    /** The emoji already chosen (your reaction), marked in the grid. */
    chosen?: string | null;
    onchoose: (character: string) => void;
  } = $props();

  const RECENT = "recent";
  const usage = new EmojiUsage(localStorage);
  let query = $state("");
  // The ones you use most, read when the picker opens: choosing one while it is open does not move them under the pointer.
  const recent: Emoji[] = usage.ranked().map(emojiFor);
  let group = $state(recent.length > 0 ? RECENT : emojiGroups[0].key);
  let scroller = $state<HTMLDivElement>();

  const results = $derived(query.trim() ? usage.usedFirst(searchEmoji(query), (e) => e.character) : []);
  const tabs = $derived([...(recent.length > 0 ? [{ key: RECENT, icon: "clock" }] : []), ...emojiGroups.map((g) => ({ key: g.key, icon: g.icon }))]);

  function groupTitle(key: string): string {
    switch (key) {
      case RECENT: return tr("Veelgebruikt", "Frequently Used");
      case "smileys": return tr("Smileys en emoties", "Smileys & Emotion");
      case "people": return tr("Mensen en lichaam", "People & Body");
      case "animals": return tr("Dieren en natuur", "Animals & Nature");
      case "food": return tr("Eten en drinken", "Food & Drink");
      case "travel": return tr("Reizen en plaatsen", "Travel & Places");
      case "activities": return tr("Activiteiten", "Activities");
      case "objects": return tr("Voorwerpen", "Objects");
      case "symbols": return tr("Symbolen", "Symbols");
      case "flags": return tr("Vlaggen", "Flags");
      default: return key;
    }
  }

  /** Counts the choice (not taking your reaction back), then passes it on. */
  function pick(character: string) {
    if (character !== chosen) usage.record(character);
    onchoose(character);
  }

  function jump(key: string) {
    group = key;
    const target = scroller?.querySelector<HTMLElement>(`[data-group="${key}"]`);
    if (scroller && target) scroller.scrollTo({ top: target.offsetTop - scroller.offsetTop, behavior: "smooth" });
  }
</script>

{#snippet grid(list: Emoji[])}
  <div class="grid">
    {#each list as emoji (emoji.character)}
      <button type="button" class="cell" class:chosen={emoji.character === chosen} use:tip={emoji.name} aria-label={emoji.name} onclick={() => pick(emoji.character)}>{emoji.character}</button>
    {/each}
  </div>
{/snippet}

<div class="emoji-browser">
  <SearchField bind:value={query} placeholder={tr("Zoek een emoji", "Search emoji")} autofocus onsubmit={() => results[0] && pick(results[0].character)} />
  {#if !query.trim()}
    <div class="tabs" role="tablist" aria-label={tr("Groepen", "Groups")}>
      {#each tabs as t (t.key)}
        <button type="button" role="tab" class:on={t.key === group} aria-selected={t.key === group} use:tip={groupTitle(t.key)} onclick={() => jump(t.key)}><Ico name={t.icon} size={14} stroke={2.2} /></button>
      {/each}
    </div>
  {/if}
  <div class="scroll" bind:this={scroller}>
    {#if !query.trim()}
      {#if recent.length > 0}
        <section data-group={RECENT}><h4>{groupTitle(RECENT)}</h4>{@render grid(recent)}</section>
      {/if}
      {#each emojiGroups as g (g.key)}
        <section data-group={g.key}><h4>{groupTitle(g.key)}</h4>{@render grid(g.emoji)}</section>
      {/each}
    {:else if results.length === 0}
      <p class="none">{tr("Geen emoji voor “{query}”", "No emoji for “{query}”", { query: query.trim() })}</p>
    {:else}
      {@render grid(results)}
    {/if}
  </div>
</div>

<style>
  /* Nine columns of 32 px with 2 px between them, and room for the scroll bar: the Mac's width. */
  .emoji-browser { box-sizing: content-box; display: flex; flex-direction: column; gap: var(--space-6); width: calc(9 * 34px + var(--space-12)); padding: var(--space-8); background: var(--surface); }
  .tabs { display: flex; gap: var(--space-2); }
  .tabs button { display: grid; place-items: center; width: 30px; height: 26px; padding: 0; border: none; border-radius: var(--radius-chip); background: none; color: var(--text3); }
  .tabs button:hover:not(:disabled) { background: var(--row-hover); color: var(--text-strong); }
  .tabs button.on, .tabs button.on:hover:not(:disabled) { background: var(--row-selected); color: var(--paper); }
  .scroll { height: 260px; overflow-y: auto; position: relative; }
  section { display: flex; flex-direction: column; gap: var(--space-6); padding-bottom: var(--space-6); }
  h4 { position: sticky; top: 0; z-index: 1; margin: 0; padding: var(--space-2) 0; font: var(--text-label); color: var(--text3); background: var(--surface); }
  .grid { display: grid; grid-template-columns: repeat(9, 32px); gap: var(--space-2); }
  .cell { width: 32px; height: 32px; padding: 0; border: none; border-radius: var(--radius-control); background: none; font: var(--text-display); line-height: 32px; text-align: center; }
  .cell:hover:not(:disabled) { background: var(--smoke); }
  .cell.chosen, .cell.chosen:hover:not(:disabled) { background: color-mix(in srgb, var(--mint) 20%, transparent); }
  .none { margin: 0; padding-top: var(--space-16); text-align: center; font: var(--text-detail); color: var(--text2); }
</style>
