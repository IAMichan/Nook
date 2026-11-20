<script lang="ts">
  // Wat Nook voor een antwoord gebruikte: één rustige regel met de iconen van de doorzochte bronnen ("3 bronnen
  // gebruikt", met apart "1 niet gelezen") die openklapt. Per bron een gekleurd label (gevonden, niets gevonden, als
  // context, niet gelezen, zoekt); bronnen die niet gelezen konden worden staan bovenaan, met de reden en Probeer
  // opnieuw op één regel. Na elk antwoord dicht, zoals op de Mac.
  import { openUrl } from "@tauri-apps/plugin-opener";
  import { citationsUsed, isOpenableUrl } from "../lib/citations";
  import { sourceSymbol, sourceDomain, sourceGroups, sourcesSummary, sourceTitle, statusText, type SourceGroup } from "../lib/sources";
  import type { ChatMessage, SourceReference } from "../lib/types";
  import ServiceIcon from "../views/connectors/ServiceIcon.svelte";
  import { tr } from "../lib/i18n.svelte";
  import CitationPreview from "./CitationPreview.svelte";
  import Ico from "./ui/Ico.svelte";

  let { message, live = false, onRetry }: { message: ChatMessage; live?: boolean; onRetry?: () => void } = $props();

  const groups = $derived(sourceGroups(message, live));
  const cited = $derived(citationsUsed(message.text));
  const failed = $derived(groups.filter((g) => g.status === "failed").length);
  const searching = $derived(live && groups.some((g) => g.status === "running"));
  const summary = $derived(sourcesSummary(groups, live));
  let expanded = $state(false);
  // Closed after every answer (`SourcesDisclosure`): opened while Nook searched, it folds away once the answer is done;
  // a source that could not be read shows as the badge on the line.
  let wasLive = false;
  $effect(() => {
    if (wasLive && !live) expanded = false;
    wasLive = live;
  });

  let previewRef = $state<SourceReference | null>(null);
  let previewAnchor = $state<{ left: number; top: number; right: number; bottom: number } | null>(null);
  let onRow = false;
  let onPopover = false;
  let showTimer: ReturnType<typeof setTimeout> | undefined;
  let hideTimer: ReturnType<typeof setTimeout> | undefined;

  function clearTimers() {
    clearTimeout(showTimer);
    clearTimeout(hideTimer);
  }

  function scheduleClose() {
    clearTimeout(hideTimer);
    hideTimer = setTimeout(() => {
      if (!onRow && !onPopover) {
        previewRef = null;
        previewAnchor = null;
      }
    }, 200);
  }

  function enterRow(ref: SourceReference, el: HTMLElement) {
    onRow = true;
    clearTimers();
    const rect = el.getBoundingClientRect();
    const anchor = { left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom };
    const delay = previewRef ? 0 : 400;
    showTimer = setTimeout(() => {
      previewRef = ref;
      previewAnchor = anchor;
    }, delay);
  }

  function leaveRow() {
    onRow = false;
    clearTimeout(showTimer);
    scheduleClose();
  }

  function hoverPopover(inside: boolean) {
    onPopover = inside;
    if (inside) clearTimeout(hideTimer);
    else scheduleClose();
  }

  function open(ref: SourceReference) {
    if (ref.url && isOpenableUrl(ref.url)) openUrl(ref.url);
  }

  /** The exact queries as a tooltip (a failed source shows its reason in the row itself). */
  function help(g: SourceGroup): string {
    return g.queries.map((q) => `“${q}”`).join(", ");
  }

  function refSubtitle(ref: SourceReference, groupTitle: string): string {
    const app = sourceTitle(ref.sourceId) || groupTitle;
    return [app, ref.detail].filter((s) => s && s.trim().length > 0).join(" · ");
  }
</script>

{#if groups.length}
  <div class="sources">
    <button
      class="toggle"
      onclick={() => (expanded = !expanded)}
      aria-expanded={expanded}
      aria-label={summary + (failed ? tr(", {n} niet gelezen", ", {n} not read", { n: failed }) : "")}
      title={message.scopeLabel ? tr("Alleen deze bronnen mochten voor dit antwoord: {sources}", "Only these sources were allowed for this answer: {sources}", { sources: message.scopeLabel }) : tr("Toon waar Nook keek", "Show where Nook looked")}
    >
      <span class="stack" aria-hidden="true">
        {#each groups.slice(0, 4) as g (g.title)}
          <span class="mini"><ServiceIcon domain={sourceDomain(g.sourceId)} glyph={sourceSymbol(g.sourceId ?? "")} title={g.title} size={14} /></span>
        {/each}
      </span>
      <span>{summary}</span>
      {#if failed > 0 && !searching}<span class="badge">{tr("{n} niet gelezen", "{n} not read", { n: failed })}</span>{/if}
      <span class="chev" class:open={expanded} aria-hidden="true"><Ico name="chevron-down" size={8} stroke={2.6} /></span>
    </button>
    {#if expanded}
      <div class="list">
        {#each groups as g (g.title)}
          <div class="group" class:failed={g.status === "failed"}>
            <div class="head" title={help(g)}>
              <ServiceIcon domain={sourceDomain(g.sourceId)} glyph={sourceSymbol(g.sourceId ?? "")} title={g.title} size={16} />
              <span class="name">{g.title}</span>
              <span class="chip {g.status}">
                {#if g.status === "running"}<span class="spin"></span>{/if}
                {statusText(g)}
              </span>
            </div>
            {#if g.status === "failed"}
              <div class="failure">
                <span class="reason">{g.reason}</span>
                {#if onRetry}<button class="fix" onclick={onRetry}>↻ {tr("Probeer opnieuw", "Try again")}</button>{/if}
              </div>
            {/if}
            {#if !live && g.references.length}
              <div class="refs-list">
                {#each g.references as ref (ref.number)}
                  {@const isCited = cited.has(ref.number)}
                  {@const openable = isOpenableUrl(ref.url)}
                  <button
                    type="button"
                    class="ref-row"
                    class:cited={isCited}
                    class:openable
                    aria-label={ref.title}
                    title={openable ? tr("Open het origineel", "Open the original") : tr("Geen link beschikbaar voor deze bron", "No link available for this source")}
                    onclick={() => open(ref)}
                    onmouseenter={(e) => enterRow(ref, e.currentTarget)}
                    onmouseleave={leaveRow}
                  >
                    <span class="ref-dot" aria-hidden="true"></span>
                    <span class="ref-text">
                      <span class="ref-title">{ref.title}</span>
                      <span class="ref-sub">{refSubtitle(ref, g.title)}</span>
                    </span>
                    {#if openable}<span class="ref-arrow" aria-hidden="true">↗</span>{/if}
                  </button>
                {/each}
              </div>
            {/if}
          </div>
        {/each}
      </div>
    {/if}
  </div>
{/if}

{#if previewRef && previewAnchor}
  <CitationPreview
    references={[previewRef]}
    anchor={previewAnchor}
    edge="right"
    onhover={hoverPopover}
    onopen={() => { previewRef = null; previewAnchor = null; }}
  />
{/if}

<style>
  .sources { font-size: 12px; }
  .toggle { display: inline-flex; align-items: center; gap: 7px; background: none; border: none; padding: 3px 0; color: var(--text2); font: var(--text-label); }
  .toggle:hover { background: none; color: var(--paper); }
  .stack { display: inline-flex; }
  .stack .mini { display: inline-flex; padding: 1.5px; border-radius: 50%; background: var(--graphite); border: 1px solid var(--ink); margin-left: -4px; overflow: hidden; }
  .stack .mini:first-child { margin-left: 0; }
  .badge { font-size: 10.5px; font-weight: 600; color: var(--amber); padding: 2px 7px; border-radius: 999px; background: color-mix(in srgb, var(--amber) 12%, transparent); }
  .chev { display: inline-flex; color: var(--text3); transition: transform 0.16s ease-out; }
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
  .refs-list { display: flex; flex-direction: column; padding-left: 20px; }
  .ref-row {
    display: flex;
    align-items: baseline;
    gap: 7px;
    width: 100%;
    text-align: left;
    padding: 4px 6px;
    border-radius: var(--radius-control);
    border: none;
    background: transparent;
  }
  .ref-row:hover { background: var(--smoke); }
  .ref-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    flex: none;
    align-self: center;
    background: var(--smoke);
  }
  .ref-row.cited .ref-dot { background: var(--iris); }
  .ref-text { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 1px; }
  .ref-title {
    font: var(--text-detail);
    color: var(--text2);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .ref-row.cited .ref-title { color: var(--paper); }
  .ref-sub {
    font: var(--text-label);
    color: var(--text3);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .ref-arrow { font: var(--text-caption); font-weight: 600; color: var(--text3); flex: none; }
  .ref-row:hover .ref-arrow { color: var(--paper); }
</style>
