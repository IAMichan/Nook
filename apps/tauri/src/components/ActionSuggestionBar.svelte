<script lang="ts">
  // Above a conversation's field: what Nook could do for what was just said (`ActionSuggestionBar` on the Mac). Before
  // you act, one quiet line on a dashed outline (the steps, Do it and the cross; why Nook proposes it on hover, the
  // steps in full on a click); once it runs, the card that says how it went. It asks for a look whenever the newest
  // message (`turn`) or `busy` changes.
  import { untrack } from "svelte";
  import { tr } from "../lib/i18n.svelte";
  import { actionSuggestions, type Line, type Place, type Turn } from "../lib/action-suggestions.svelte";
  import Ico from "./ui/Ico.svelte";

  let { turn, busy = false, place, lines, nookId = null, enabled = true }: {
    turn: Turn | null; busy?: boolean; place: Place; lines: () => Line[]; nookId?: string | null; enabled?: boolean;
  } = $props();

  let expanded = $state(false);
  const conversation = $derived(turn?.conversation ?? "");
  const shown = $derived(conversation ? actionSuggestions.shown(conversation) : null);
  const many = (n: number) => tr("{n} stappen uitgevoerd", "{n} steps done", { n });

  $effect(() => {
    const t = turn, b = busy, on = enabled;
    untrack(() => actionSuggestions.request(t, b, place, lines, on));
  });
  $effect(() => {
    void conversation;
    expanded = false;
  });
</script>

{#if shown && shown.run.kind === "waiting"}
  <div class="whisper" class:expanded role="group" aria-label={tr("Nook stelt voor", "Nook suggests")}>
    <span class="mark"><Ico name="sparkles" size={12} stroke={2.4} /></span>
    <button class="steps" title={expanded ? undefined : (shown.reason ?? undefined)} aria-expanded={expanded} onclick={() => (expanded = !expanded)}>
      {#each shown.actions as step, i (i)}<span class="step">{step.summary}</span>{/each}
      {#if expanded && shown.reason}<span class="reason">{shown.reason}</span>{/if}
    </button>
    <button class="ghost-button" onclick={() => actionSuggestions.run(conversation, nookId, many)}><Ico name="check" size={12} stroke={2.4} />{tr("Uitvoeren", "Do it")}</button>
    <button class="icon-button" title={tr("Laat dit voorstel gaan", "Let this proposal go")} aria-label={tr("Laat dit voorstel gaan", "Let this proposal go")} onclick={() => actionSuggestions.dismiss(conversation)}><Ico name="x" size={13} /></button>
  </div>
{:else if shown}
  <div class="card" role="status">
    <div class="card-head">
      <span class="title">{tr("Nook stelt voor", "Nook suggests")}</span>
      <span class="grow"></span>
      {#if shown.run.kind !== "running"}
        <button class="icon-button" title={tr("Laat dit voorstel gaan", "Let this proposal go")} aria-label={tr("Laat dit voorstel gaan", "Let this proposal go")} onclick={() => actionSuggestions.dismiss(conversation)}><Ico name="x" size={13} /></button>
      {/if}
    </div>
    {#each shown.actions as step, i (i)}
      <div class="row"><Ico name={shown.run.kind === "done" ? "circle-check" : shown.run.kind === "failed" ? "triangle-alert" : "loader-circle"} size={13} /><span>{step.summary}</span></div>
    {/each}
    {#if shown.run.kind === "done" || shown.run.kind === "failed"}<p class="result" class:failed={shown.run.kind === "failed"}>{shown.run.text}</p>{/if}
  </div>
{/if}

<style>
  /* A suggestion before you act: one quiet line on a dashed outline, on the composer tray's fill. */
  .whisper { display: flex; align-items: center; gap: var(--space-6); margin: 0 0 var(--space-8); padding: var(--space-6) var(--space-6) var(--space-6) var(--space-12); background: var(--composer-tray, var(--graphite)); border: 1px dashed var(--field-stroke); border-radius: var(--radius-sheet); transition: border-color var(--motion-hover); }
  .whisper:hover, .whisper.expanded { border-style: solid; }
  .whisper.expanded { align-items: flex-start; }
  .mark { display: inline-flex; color: var(--text3); flex: none; }
  .whisper:hover .mark { color: var(--iris); }
  .steps { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: var(--space-2); padding: 0; border: 0; background: transparent; text-align: left; }
  .step { font: var(--text-detail); color: var(--text2); display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
  .whisper:hover .step, .whisper.expanded .step { color: var(--text-strong); }
  .expanded .step { display: block; }
  .reason { font: var(--text-caption); color: var(--text3); }
  .ghost-button { display: inline-flex; align-items: center; gap: var(--space-4); flex: none; padding: var(--space-4) var(--space-8); border: 1px solid var(--line2); border-radius: var(--radius-control); background: transparent; color: var(--paper); font: var(--text-label); }
  .ghost-button:hover { background: var(--row-hover); }
  .icon-button { display: inline-flex; align-items: center; justify-content: center; width: 24px; height: 24px; padding: 0; flex: none; border: 0; border-radius: var(--radius-control); background: transparent; color: var(--text2); }
  .icon-button:hover { background: var(--row-hover); color: var(--paper); }
  .card { display: flex; flex-direction: column; gap: var(--space-6); margin: 0 0 var(--space-8); padding: var(--space-12) var(--space-16); background: var(--composer-tray, var(--graphite)); border: 1px solid var(--field-stroke); border-radius: var(--radius-sheet); }
  .card-head { display: flex; align-items: center; gap: var(--space-6); }
  .title { font: var(--text-label); color: var(--text3); }
  .grow { flex: 1; }
  .row { display: flex; align-items: flex-start; gap: var(--space-6); font: var(--text-detail); color: var(--text-strong); }
  .row :global(svg) { margin-top: var(--space-2); color: var(--text3); flex: none; }
  .result { margin: 0; font: var(--text-detail); color: var(--text2); }
  .result.failed { color: var(--coral); }
</style>
