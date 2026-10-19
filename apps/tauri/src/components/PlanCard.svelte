<script lang="ts">
  // Een plan van het brein: per stap wat er gebeurt, met alle details en aan te passen tekstvelden. Problemen staan bij de
  // stap en blokkeren Uitvoeren. Er gebeurt niets tot je op Uitvoeren klikt; een stap die al lukte, draait nooit opnieuw.
  import { api } from "../lib/api";
  import { brainApi } from "../lib/brain";
  import type { ChatMessage, PlanStep } from "../lib/types";

  let { nookId, message }: { nookId: string; message: ChatMessage } = $props();
  let steps = $state<PlanStep[]>([]);
  let open = $state<Record<number, boolean>>({});
  let editing = $state<Record<string, string>>({});
  let error = $state<string | null>(null);

  $effect(() => {
    void JSON.stringify(message.actions);
    api.planSteps(nookId, message.id).then((s) => (steps = s));
  });

  const included = $derived(message.actionIncluded.length ? message.actionIncluded : message.actions.map(() => true));
  const planState = $derived(message.planState?.kind ?? "pending");
  const editable = $derived(planState === "pending" || planState === "failed");
  const blocked = $derived(message.actions.some((_, i) => included[i] && (message.actionProblems[i]?.length ?? 0) > 0));
  const finished = (i: number) => ["done", "verified", "skipped", "duplicate"].includes(message.actionStates[i]?.kind ?? "");

  function stepLabel(i: number): { text: string; cls: string } {
    const s = message.actionStates[i];
    switch (s?.kind) {
      case "done": return { text: `✓ ${s.detail ?? ""}`, cls: "ok" };
      case "verified": return { text: `✓ ${s.detail ?? ""} · gecontroleerd`, cls: "ok" };
      case "failed": return { text: `✗ ${s.detail ?? ""}`, cls: "bad" };
      case "skipped": return { text: "Overgeslagen", cls: "faint" };
      case "notRun": return { text: "Niet uitgevoerd (een eerdere stap mislukte)", cls: "faint" };
      case "duplicate": return { text: `Al uitgevoerd op ${s.detail}; niet herhaald`, cls: "warn" };
      case "approved": return { text: "Goedgekeurd, wacht op zijn beurt", cls: "muted" };
      case "running": return { text: "Bezig…", cls: "muted" };
      default: return { text: "", cls: "" };
    }
  }

  async function saveField(i: number, key: string) {
    const token = `${i}#${key}`;
    const value = editing[token];
    delete editing[token];
    if (value === undefined) return;
    try {
      await brainApi.planEdit(nookId, message.id, i, key, value);
      steps = await api.planSteps(nookId, message.id);
    } catch (e) {
      error = String(e);
    }
  }

  async function run() {
    error = null;
    try {
      await api.executePlan(nookId, message.id, included);
    } catch (e) {
      error = String(e);
    }
  }

  const title = $derived(
    editable
      ? message.actions.length === 1 ? "VOORSTEL · CONTROLEER EN KEUR GOED" : `PLAN · ${message.actions.length} STAPPEN · CONTROLEER EN KEUR GOED`
      : planState === "running" ? "BEZIG" : planState === "cancelled" ? "GEANNULEERD" : "UITGEVOERD",
  );
</script>

<div class="plan" class:done={planState === "done"} class:failed={planState === "failed"}>
  <div class="head">
    <span class="dot {editable ? 'waiting' : planState === 'running' ? 'working' : planState === 'failed' ? 'error' : 'unread'}"></span>
    <span class="title">{title}</span>
  </div>
  {#each message.actions as action, i (action.id)}
    {@const label = stepLabel(i)}
    {@const step = steps[i]}
    <div class="step" class:off={!included[i]}>
      <label class="main">
        <input type="checkbox" checked={included[i]} disabled={!editable || finished(i)}
          title={included[i] ? "Deze stap overslaan" : "Deze stap toch uitvoeren"}
          onchange={(e) => brainApi.planInclude(nookId, message.id, i, e.currentTarget.checked)} />
        <span class="num">{i + 1}</span>
        <span>{step?.summary ?? action.tool}</span>
        {#if step?.tag}<span class="tag">{step.tag}</span>{/if}
      </label>
      <button class="ghost tiny" onclick={() => (open[i] = !open[i])}>{open[i] ? "Minder" : "Alle details"}</button>
      {#if label.text}<div class="result {label.cls}">{label.text}
        {#if message.actionStates[i]?.kind === "duplicate"}<button class="ghost tiny" onclick={() => brainApi.planRunAgain(nookId, message.id, i)}>Toch nog een keer</button>{/if}
      </div>{/if}
      {#each message.actionProblems[i] ?? [] as problem (problem)}<div class="result bad">⚠ {problem}</div>{/each}
      {#if open[i] && step}
        <div class="fields">
          {#each step.fields as field (field.key)}
            {@const token = `${i}#${field.key}`}
            <div class="field">
              <span class="faint">{field.label}</span>
              {#if field.editable && editable && !finished(i) && editing[token] !== undefined}
                {#if field.multiline}
                  <textarea rows="5" bind:value={editing[token]}></textarea>
                {:else}
                  <input bind:value={editing[token]} onkeydown={(e) => e.key === "Enter" && saveField(i, field.key)} />
                {/if}
                <button class="tiny" onclick={() => saveField(i, field.key)}>Klaar</button>
              {:else}
                <span class="value" class:multi={field.multiline}>{field.value}</span>
                {#if field.editable && editable && !finished(i)}
                  <button class="ghost tiny" onclick={() => (editing[token] = field.value)}>Aanpassen</button>
                {/if}
              {/if}
            </div>
          {/each}
        </div>
      {/if}
    </div>
  {/each}
  {#if error}<p class="result bad">{error}</p>{/if}
  {#if message.planState?.kind === "failed" || message.planState?.kind === "done"}
    <div class="outcome {message.planState.kind === 'failed' ? 'bad' : 'ok'}">{message.planState.detail}</div>
  {/if}
  {#if editable}
    <div class="buttons">
      <button class="ghost" onclick={() => api.cancelPlan(nookId, message.id)}>Annuleer</button>
      <button class="primary" disabled={!included.some(Boolean) || blocked} title={blocked ? "Los eerst de problemen bij de stappen op" : ""} onclick={run}>
        {planState === "failed" ? "Verder met de rest" : "Uitvoeren"}
      </button>
    </div>
  {/if}
</div>

<style>
  .plan { margin-top: 8px; border: 1px solid var(--line2); border-radius: 12px; padding: 10px; background: var(--field); }
  .plan.done { border-color: color-mix(in srgb, var(--mint) 35%, var(--line2)); }
  .plan.failed { border-color: color-mix(in srgb, var(--coral) 40%, var(--line2)); }
  .head { display: flex; align-items: center; gap: 8px; margin-bottom: 6px; }
  .title { font-size: 11px; letter-spacing: 0.04em; color: var(--text2); font-weight: 600; }
  .step { padding: 6px 0; border-top: 1px solid var(--line); display: grid; grid-template-columns: 1fr auto; gap: 4px; }
  .step:first-of-type { border-top: none; }
  .step.off .main span { opacity: 0.5; }
  label.main { display: flex; gap: 8px; align-items: center; }
  .num { color: var(--text3); font-size: 11px; width: 12px; }
  .tag { font-size: 10px; padding: 1px 6px; border-radius: 6px; background: color-mix(in srgb, var(--amber) 20%, transparent); color: var(--amber); }
  .result { grid-column: 1 / -1; font-size: 12px; padding-left: 44px; }
  .result.ok, .outcome.ok { color: var(--mint); }
  .result.bad, .outcome.bad { color: var(--coral); }
  .result.warn { color: var(--amber); }
  .outcome { font-size: 12px; margin-top: 6px; }
  .fields { grid-column: 1 / -1; padding-left: 44px; display: flex; flex-direction: column; gap: 6px; }
  .field { display: grid; grid-template-columns: 90px 1fr auto; gap: 8px; align-items: start; font-size: 12px; }
  .value { user-select: text; word-break: break-word; }
  .value.multi { white-space: pre-wrap; }
  .tiny { padding: 2px 8px; font-size: 11px; }
  .buttons { display: flex; justify-content: flex-end; gap: 8px; margin-top: 8px; }
</style>
