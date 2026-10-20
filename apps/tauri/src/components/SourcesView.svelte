<script lang="ts">
  // Wat Nook voor een antwoord gebruikte: één rustige regel met de iconen van de doorzochte bronnen ("3 bronnen
  // gebruikt", met apart "1 niet gelezen") die openklapt. Per bron een gekleurd label (gevonden, niets gevonden, als
  // context, niet gelezen, zoekt); bronnen die niet gelezen konden worden staan bovenaan, met de reden en Probeer
  // opnieuw op één regel. Klapt vanzelf open als een bron niet gelezen kon worden.
  import { openUrl } from "@tauri-apps/plugin-opener";
  import { sourceDomain, sourceGroups, sourcesSummary, statusText, type SourceGroup } from "../lib/sources";
  import type { ChatMessage, SourceReference } from "../lib/types";
  import ServiceIcon from "../views/connectors/ServiceIcon.svelte";

  let { message, live = false, onRetry }: { message: ChatMessage; live?: boolean; onRetry?: () => void } = $props();

  const groups = $derived(sourceGroups(message, live));
  const failed = $derived(groups.filter((g) => g.status === "failed").length);
  const searching = $derived(live && groups.some((g) => g.status === "running"));
  const summary = $derived(sourcesSummary(groups, live));
  let expanded = $state(false);
  $effect(() => {
    if (failed > 0) expanded = true;
  });

  function open(ref: SourceReference) {
    if (ref.url && /^(https:|file:|message:)/.test(ref.url)) openUrl(ref.url);
  }

  /** The exact queries as a tooltip (a failed source shows its reason in the row itself). */
  function help(g: SourceGroup): string {
    return g.queries.map((q) => `“${q}”`).join(", ");
  }
</script>

{#if groups.length}
  <div class="sources">
    <button
      class="toggle"
      onclick={() => (expanded = !expanded)}
      aria-expanded={expanded}
      aria-label={summary + (failed ? `, ${failed} niet gelezen` : "")}
      title={message.scopeLabel ? `Alleen deze bronnen mochten voor dit antwoord: ${message.scopeLabel}` : "Toon waar Nook keek"}
    >
      <span class="stack" aria-hidden="true">
        {#each groups.slice(0, 4) as g (g.title)}
          <span class="mini"><ServiceIcon domain={sourceDomain(g.sourceId)} title={g.title} size={14} /></span>
        {/each}
      </span>
      <span>{summary}</span>
      {#if failed > 0 && !searching}<span class="badge">{failed} niet gelezen</span>{/if}
      <span class="chev" class:open={expanded}>▾</span>
    </button>
    {#if expanded}
      <div class="list">
        {#each groups as g (g.title)}
          <div class="group" class:failed={g.status === "failed"}>
            <div class="head" title={help(g)}>
              <ServiceIcon domain={sourceDomain(g.sourceId)} title={g.title} size={16} />
              <span class="name">{g.title}</span>
              <span class="chip {g.status}">
                {#if g.status === "running"}<span class="spin"></span>{/if}
                {statusText(g)}
              </span>
            </div>
            {#if g.status === "failed"}
              <div class="failure">
                <span class="reason">{g.reason}</span>
                {#if onRetry}<button class="fix" onclick={onRetry}>↻ Probeer opnieuw</button>{/if}
              </div>
            {/if}
            {#if !live && g.references.length}
              <ol>
                {#each g.references as ref (ref.number)}
                  <li value={ref.number}>
                    {#if ref.url}<a href={ref.url} onclick={(e) => { e.preventDefault(); open(ref); }}>{ref.title}</a>{:else}{ref.title}{/if}
                    {#if ref.detail}<span class="faint"> — {ref.detail}</span>{/if}
                  </li>
                {/each}
              </ol>
            {/if}
          </div>
        {/each}
      </div>
    {/if}
  </div>
{/if}

<style>
  .sources { margin: 2px 0 6px; font-size: 12px; }
  .toggle { display: inline-flex; align-items: center; gap: 7px; background: none; border: none; padding: 2px 0; color: var(--text2); font-size: 12px; font-weight: 500; }
  .toggle:hover { background: none; color: var(--paper); }
  .stack { display: inline-flex; }
  .stack .mini { display: inline-flex; padding: 1.5px; border-radius: 50%; background: var(--graphite); border: 1px solid var(--ink); margin-left: -4px; overflow: hidden; }
  .stack .mini:first-child { margin-left: 0; }
  .badge { font-size: 10.5px; font-weight: 600; color: var(--amber); padding: 2px 7px; border-radius: 999px; background: color-mix(in srgb, var(--amber) 12%, transparent); }
  .chev { font-size: 9px; color: var(--text3); transition: transform 0.16s ease-out; }
  .chev.open { transform: rotate(180deg); }
  .list { margin-top: 6px; padding: 4px; border-radius: 12px; background: var(--field); border: 1px solid color-mix(in srgb, var(--line2) 70%, transparent); }
  .group { padding: 7px 8px; border-radius: 9px; display: flex; flex-direction: column; gap: 4px; }
  .group + .group { border-top: 1px solid color-mix(in srgb, var(--line2) 60%, transparent); }
  .group.failed { background: color-mix(in srgb, var(--coral) 6%, transparent); }
  .head { display: flex; align-items: center; gap: 8px; }
  .name { flex: 1; min-width: 0; font-size: 12.5px; font-weight: 500; color: color-mix(in srgb, var(--paper) 88%, transparent); }
  .group.failed .name { color: var(--paper); }
  .chip { display: inline-flex; align-items: center; gap: 4px; font-size: 10.5px; font-weight: 600; padding: 2px 7px; border-radius: 999px; white-space: nowrap; color: var(--text3); background: var(--smoke); }
  .chip.found { color: var(--mint); background: color-mix(in srgb, var(--mint) 10%, transparent); }
  .chip.failed { color: var(--coral); background: color-mix(in srgb, var(--coral) 12%, transparent); }
  .chip.running { color: var(--iris); background: color-mix(in srgb, var(--iris) 12%, transparent); }
  .spin { width: 8px; height: 8px; border-radius: 50%; border: 1.5px solid currentColor; border-top-color: transparent; animation: spin 0.8s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
  .failure { display: flex; align-items: center; gap: 10px; padding-left: 24px; }
  .reason { flex: 1; font-size: 11.5px; color: var(--text2); user-select: text; }
  .fix { font-size: 11px; font-weight: 600; padding: 3px 9px; border-radius: 999px; border: none; background: var(--smoke); color: var(--paper); white-space: nowrap; }
  ol { margin: 0 0 0 20px; padding-left: 16px; color: var(--text2); }
</style>
