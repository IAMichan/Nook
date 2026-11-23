<script lang="ts">
  // Een plan dat de agent in Plan-modus voorstelde (`PlanCard` op de Mac): het plan zelf, kopiëren, bewaren als
  // bestand, en de knop die het uitvoert (modus Agent, dan "voer het plan uit").
  import Markdown from "../../../components/Markdown.svelte";
  import { tr } from "../../../lib/i18n.svelte";
  import { planFileName, planNeedsExpand, planPreview, planTitle } from "../../../lib/workspace/timeline";
  import { keptCount, keptText, planSteps, type PlanStep } from "../../../lib/workspace/plan-checklist";
  import Ico from "../../../components/ui/Ico.svelte";

  let {
    text,
    canAct,
    onimplement,
    onimplementnew,
    baseFolder = null,
    onrun,
  }: {
    text: string;
    canAct: boolean;
    /** Carry out the plan; `kept`: the plan with only the steps you kept, when you left some out. */
    onimplement: (kept: string | null) => void;
    /** "In a new session": a fork that carries out the plan. */
    onimplementnew?: () => void;
    baseFolder?: string | null;
    onrun?: (command: string, title: string | null) => void;
  } = $props();
  let open = $state(false);
  let copied = $state(false);

  const collapsible = $derived(planNeedsExpand(text));
  // "Edit steps" (`PlanChecklist`): every list item of the plan is a step you can leave out before it runs.
  let editing = $state(false);
  let steps = $state<PlanStep[]>([]);
  const useful = $derived(planSteps(text).length >= 2);
  function toggleEditing() {
    if (!steps.length) steps = planSteps(text);
    editing = !editing;
  }
  function run() {
    const kept = keptCount(steps);
    onimplement(editing && steps.some((s) => !s.kept) && kept > 0 ? keptText(text, steps) : null);
  }

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
    a.download = planFileName(planTitle(text) ?? tr("Voorgesteld plan", "Proposed plan"));
    a.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }
</script>

<div class="plan">
  <div class="head">
    <strong>{tr("Voorgesteld plan", "Proposed plan")}</strong>
    <span class="spacer"></span>
    <button class="ghost" title={tr("Kopieer plan", "Copy plan")} onclick={copy}>{copied ? "✓" : tr("Kopieer", "Copy")}</button>
    <button class="ghost" title={tr("Bewaar als bestand", "Save as file")} onclick={save}>{tr("Bewaar", "Save")}</button>
  </div>
  {#if editing}
    <div class="steps">
      {#each steps as step (step.id)}
        <button class="step" class:out={!step.kept} style:padding-left="calc({step.indent} * var(--space-4))" onclick={() => (step.kept = !step.kept)}>
          <span class="mark" class:kept={step.kept}><Ico name={step.kept ? "circle-check" : "circle"} size={14} /></span><span class="stext">{step.text}</span>
        </button>
      {/each}
      <span class="kept-count">{tr("{kept} van {total} stappen worden uitgevoerd", "{kept} of {total} steps will run", { kept: keptCount(steps), total: steps.length })}</span>
    </div>
  {:else}
    <Markdown text={collapsible && !open ? planPreview(text) : text} {baseFolder} {onrun} />
  {/if}
  {#if collapsible && !editing}
    <button class="ghost more" onclick={() => (open = !open)}>{open ? tr("Toon minder", "Show less") : tr("Toon volledig plan", "Show full plan")}</button>
  {/if}
  {#if canAct}
    <div class="actions">
      <span class="spacer"></span>
      {#if onimplementnew}<button class="ghost" onclick={onimplementnew}>{tr("In een nieuwe sessie", "In a new session")}</button>{/if}
      {#if useful}<button class="ghost" onclick={toggleEditing}>{editing ? tr("Klaar met aanpassen", "Done editing") : tr("Stappen aanpassen", "Edit steps")}</button>{/if}
      <button class="primary" onclick={run}>{tr("Voer plan uit", "Run plan")}</button>
    </div>
  {/if}
</div>

<style>
  .plan { border: 1px solid var(--line2); border-radius: var(--radius-card); padding: var(--space-12); display: flex; flex-direction: column; gap: var(--space-8); }
  .steps { display: flex; flex-direction: column; gap: var(--space-6); }
  .step { display: flex; align-items: baseline; gap: var(--space-8); margin: 0; padding: var(--space-2) 0; border: 0; background: transparent; text-align: left; color: var(--paper); font: var(--text-body); }
  .step.out .stext { color: var(--text3); text-decoration: line-through; }
  .mark { color: var(--text3); display: inline-flex; transform: translateY(2px); }
  .mark.kept { color: var(--mint); }
  .kept-count { font: var(--text-detail); color: var(--text3); }
  .head { display: flex; align-items: center; gap: 6px; font-size: 12px; }
  .spacer { flex: 1; }
  .more { align-self: flex-start; font-size: 12px; }
  .actions { display: flex; gap: 8px; }
</style>
