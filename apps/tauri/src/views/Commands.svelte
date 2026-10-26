<script lang="ts">
  // What you can ask Nook (click one to put it in the chat field), and what the bar itself can do.
  import { askGroups, barCommands, type Pair } from "../lib/bar-commands";
  import { english, tr } from "../lib/i18n.svelte";

  let { onuse }: { onuse: (text: string) => void } = $props();
  const pick = (pair: Pair) => (english() ? pair[1] : pair[0]);
</script>

<div class="commands">
  <p class="intro faint">{tr("Dit kun je aan Nook vragen. Klik op een voorbeeld om het in de chatbalk te zetten.", "This is what you can ask Nook. Click an example to put it in the chat field.")}</p>
  {#each askGroups as g (g.id)}
    <section>
      <h4>{pick(g.title)}</h4>
      {#if g.note}<p class="note faint">{pick(g.note)}</p>{/if}
      <div class="asks">
        {#each g.asks as a (a[0])}
          <button class="ask" onclick={() => onuse(pick(a))}>{pick(a)}</button>
        {/each}
      </div>
    </section>
  {/each}

  <section>
    <h4>{tr("De balk zelf", "The bar itself")}</h4>
    <ul>
      {#each barCommands as c (c.id)}
        <li>
          <div class="head">
            <strong>{pick(c.title)}</strong>
            <span class="how">{pick(c.how)}</span>
          </div>
          <p>{pick(c.description)}</p>
        </li>
      {/each}
    </ul>
  </section>
</div>

<style>
  .commands { height: 100%; overflow-y: auto; padding: 4px 16px 16px; display: grid; gap: 14px; align-content: start; }
  .intro { margin: 0; font-size: 12px; }
  h4 { margin: 0 0 6px; font-size: 11px; letter-spacing: 0.06em; text-transform: uppercase; color: var(--text3); }
  .note { margin: 0 0 6px; font-size: 11px; line-height: 1.45; }
  .asks { display: flex; flex-wrap: wrap; gap: 6px; }
  .ask { text-align: left; font-size: 12px; padding: 6px 10px; border-radius: 999px; background: var(--smoke); color: var(--paper); border: 1px solid var(--line); }
  .ask:hover { border-color: color-mix(in srgb, var(--iris) 50%, var(--line)); }
  ul { list-style: none; margin: 0; padding: 0; display: grid; gap: 8px; }
  li { padding: 10px 12px; border-radius: 12px; background: var(--smoke); }
  .head { display: flex; flex-wrap: wrap; align-items: baseline; justify-content: space-between; gap: 4px 12px; }
  strong { font-size: 13px; color: var(--paper); }
  .how { font-size: 11px; color: var(--iris); }
  li p { margin: 4px 0 0; font-size: 12px; line-height: 1.5; color: var(--text2); }
</style>
