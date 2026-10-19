<script lang="ts">
  // Een plan van het brein: per stap wat er gebeurt, uit te zetten, en pas na Uitvoeren echt gedaan.
  import { api } from "../lib/api";
  import type { ChatMessage, PlanStep } from "../lib/types";

  let { nookId, message }: { nookId: string; message: ChatMessage } = $props();
  let steps = $state<PlanStep[]>([]);
  let included = $state<boolean[]>([]);
  let open = $state<Record<number, boolean>>({});

  $effect(() => {
    api.planSteps(nookId, message.id).then((s) => (steps = s));
    included = message.actionIncluded.length ? [...message.actionIncluded] : message.actions.map(() => true);
  });

  const planState = $derived(message.planState?.kind ?? "pending");
  const editable = $derived(planState === "pending");

  function stepLabel(i: number): { text: string; cls: string } {
    const s = message.actionStates[i];
    switch (s?.kind) {
      case "done": return { text: `✓ ${s.detail ?? ""}`, cls: "ok" };
      case "failed": return { text: `✗ ${s.detail ?? ""}`, cls: "bad" };
      case "skipped": return { text: "overgeslagen", cls: "faint" };
      case "duplicate": return { text: `al gedaan om ${s.detail}`, cls: "faint" };
      case "running": return { text: "bezig…", cls: "muted" };
      default: return { text: "", cls: "" };
    }
  }
</script>

<div class="plan" class:done={planState === "done"} class:failed={planState === "failed"}>
  <div class="head">
    <span class="dot {editable ? 'waiting' : planState === 'running' ? 'working' : planState === 'failed' ? 'error' : 'unread'}"></span>
    <strong>{editable ? "Voorstel" : planState === "running" ? "Bezig" : planState === "cancelled" ? "Geannuleerd" : planState === "failed" ? "Deels mislukt" : "Uitgevoerd"}</strong>
    <span class="faint">{message.actions.length} {message.actions.length === 1 ? "stap" : "stappen"}</span>
  </div>
  {#each message.actions as action, i (action.id)}
    {@const label = stepLabel(i)}
    <div class="step">
      <label>
        <input type="checkbox" bind:checked={included[i]} disabled={!editable} />
        <span>{steps[i]?.summary ?? action.tool}</span>
      </label>
      <button class="ghost tiny" onclick={() => (open[i] = !open[i])}>{open[i] ? "Minder" : "Details"}</button>
      {#if label.text}<div class="result {label.cls}">{label.text}</div>{/if}
      {#if message.actionProblems[i]?.length}<div class="result bad">{message.actionProblems[i].join("; ")}</div>{/if}
      {#if open[i]}
        <pre>{JSON.stringify(action.input, null, 2)}</pre>
      {/if}
    </div>
  {/each}
  {#if editable}
    <div class="buttons">
      <button class="ghost" onclick={() => api.cancelPlan(nookId, message.id)}>Annuleer</button>
      <button class="primary" disabled={!included.some(Boolean)} onclick={() => api.executePlan(nookId, message.id, included)}>Uitvoeren</button>
    </div>
  {/if}
</div>

<style>
  .plan { margin-top: 8px; border: 1px solid var(--line2); border-radius: 12px; padding: 10px; background: var(--field); }
  .plan.done { border-color: color-mix(in srgb, var(--mint) 35%, var(--line2)); }
  .plan.failed { border-color: color-mix(in srgb, var(--coral) 40%, var(--line2)); }
  .head { display: flex; align-items: center; gap: 8px; margin-bottom: 6px; }
  .step { padding: 6px 0; border-top: 1px solid var(--line); display: grid; grid-template-columns: 1fr auto; gap: 4px; }
  .step:first-of-type { border-top: none; }
  label { display: flex; gap: 8px; align-items: center; }
  .result { grid-column: 1 / -1; font-size: 12px; padding-left: 24px; }
  .result.ok { color: var(--mint); }
  .result.bad { color: var(--coral); }
  pre { grid-column: 1 / -1; margin: 0; font-family: var(--mono); font-size: 11px; color: var(--text2); white-space: pre-wrap; user-select: text; }
  .tiny { padding: 2px 8px; font-size: 11px; }
  .buttons { display: flex; justify-content: flex-end; gap: 8px; margin-top: 8px; }
</style>
