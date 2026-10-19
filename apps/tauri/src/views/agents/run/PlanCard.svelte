<script lang="ts">
  // Een plan dat de agent in Plan-modus voorstelde (`PlanCard` op de Mac): het plan zelf, kopiëren, bewaren als
  // bestand, en de knop die het uitvoert (modus Agent, dan "voer het plan uit").
  import { renderMarkdown } from "../../../lib/markdown";
  import { planFileName, planNeedsExpand, planPreview, planTitle } from "../../../lib/workspace/timeline";

  let { text, canAct, onimplement }: { text: string; canAct: boolean; onimplement: () => void } = $props();
  let open = $state(false);
  let copied = $state(false);

  const collapsible = $derived(planNeedsExpand(text));

  function copy() {
    navigator.clipboard?.writeText(text).then(() => {
      copied = true;
      setTimeout(() => (copied = false), 1500);
    });
  }

  /// "Bewaar als bestand": een download met de titel van het plan als naam.
  function save() {
    const url = URL.createObjectURL(new Blob([text], { type: "text/markdown" }));
    const a = document.createElement("a");
    a.href = url;
    a.download = planFileName(planTitle(text) ?? "Voorgesteld plan");
    a.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }
</script>

<div class="plan">
  <div class="head">
    <strong>Voorgesteld plan</strong>
    <span class="spacer"></span>
    <button class="ghost" title="Kopieer plan" onclick={copy}>{copied ? "✓" : "Kopieer"}</button>
    <button class="ghost" title="Bewaar als bestand" onclick={save}>Bewaar</button>
  </div>
  <div class="markdown">{@html renderMarkdown(collapsible && !open ? planPreview(text) : text)}</div>
  {#if collapsible}
    <button class="ghost more" onclick={() => (open = !open)}>{open ? "Toon minder" : "Toon volledig plan"}</button>
  {/if}
  {#if canAct}
    <div class="actions"><span class="spacer"></span><button class="primary" onclick={onimplement}>Voer plan uit</button></div>
  {/if}
</div>

<style>
  .plan { border: 1px solid rgba(244, 243, 247, 0.25); border-radius: 12px; padding: 12px; display: flex; flex-direction: column; gap: 10px; }
  .head { display: flex; align-items: center; gap: 6px; font-size: 12px; }
  .spacer { flex: 1; }
  .more { align-self: flex-start; font-size: 12px; }
  .actions { display: flex; gap: 8px; }
</style>
