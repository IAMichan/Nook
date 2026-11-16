<script lang="ts">
  // Een plan van het brein: per stap wat er gebeurt, met alle details en aan te passen tekstvelden. Problemen staan bij de
  // stap en blokkeren Uitvoeren. Er gebeurt niets tot je op Uitvoeren klikt; een stap die al lukte, draait nooit opnieuw.
  import { api } from "../lib/api";
  import { brainApi } from "../lib/brain";
  import type { ChatMessage, PlanStep } from "../lib/types";
  import { tr } from "../lib/i18n.svelte";

  let { nookId, message, last = false }: { nookId: string; message: ChatMessage; last?: boolean } = $props();
  let steps = $state<PlanStep[]>([]);
  let open = $state<Record<number, boolean>>({});
  let editing = $state<Record<string, string>>({});
  let error = $state<string | null>(null);

  // Each update replaces the whole conversation, so `message` is a new object every time: compare the actions by value,
  // or every plan card in the chat fetches its steps again on every update.
  const actionsKey = $derived(JSON.stringify(message.actions));
  const messageId = $derived(message.id);
  $effect(() => {
    void actionsKey;
    let stale = false;
    api
      .planSteps(nookId, messageId)
      .then((s) => {
        if (!stale) steps = s;
      })
      .catch(() => {});
    return () => {
      stale = true;
    };
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
      case "verified": return { text: tr("✓ {detail} · gecontroleerd", "✓ {detail} · checked", { detail: s.detail ?? "" }), cls: "ok" };
      case "failed": return { text: `✗ ${s.detail ?? ""}`, cls: "bad" };
      case "skipped": return { text: tr("Overgeslagen", "Skipped"), cls: "faint" };
      case "notRun": return { text: tr("Niet uitgevoerd (een eerdere stap mislukte)", "Not run (an earlier step failed)"), cls: "faint" };
      case "duplicate": return { text: tr("Al uitgevoerd op {when}; niet herhaald", "Already run on {when}; not repeated", { when: s.detail ?? "" }), cls: "warn" };
      case "approved": return { text: tr("Goedgekeurd, wacht op zijn beurt", "Approved, waiting for its turn"), cls: "muted" };
      case "running": return { text: tr("Bezig…", "Working…"), cls: "muted" };
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

  let running = false;
  async function run() {
    if (running) return;
    running = true;
    error = null;
    try {
      await api.executePlan(nookId, message.id, included);
    } catch (e) {
      error = String(e);
    } finally {
      running = false;
    }
  }

  /** Ctrl+Enter runs the newest plan that waits for you, without reaching for the mouse. */
  function runKey(e: KeyboardEvent) {
    if (!last || !editable || blocked || running || !included.some(Boolean)) return;
    if (e.key !== "Enter" || !(e.ctrlKey || e.metaKey) || e.shiftKey || e.altKey || e.isComposing || e.defaultPrevented) return;
    const target = e.target instanceof Element ? e.target : null;
    // Ctrl+Enter inside a field you are editing in the plan stays there.
    if (target?.closest(".plan textarea, .plan input")) return;
    e.preventDefault();
    run();
  }

  /** Zet de cursor meteen in een veld dat je gaat aanpassen. */
  function focusField(node: HTMLInputElement | HTMLTextAreaElement) {
    node.focus();
    node.select();
  }

  /** Bij één stap staat de uitkomst al bij de stap. */
  const outcomeShown = $derived(
    !(message.actions.length === 1 && message.planState?.detail && message.actionStates[0]?.detail === message.planState.detail),
  );

  const title = $derived(
    editable
      ? message.actions.length === 1 ? tr("VOORSTEL · CONTROLEER EN KEUR GOED", "PROPOSAL · REVIEW AND APPROVE") : tr("PLAN · {n} STAPPEN · CONTROLEER EN KEUR GOED", "PLAN · {n} STEPS · REVIEW AND APPROVE", { n: message.actions.length })
      : planState === "running" ? tr("BEZIG", "RUNNING") : planState === "cancelled" ? tr("GEANNULEERD", "CANCELLED") : tr("UITGEVOERD", "DONE"),
  );
</script>

<svelte:window onkeydown={runKey} />

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
          title={included[i] ? tr("Deze stap overslaan", "Skip this step") : tr("Deze stap toch uitvoeren", "Run this step after all")}
          onchange={(e) => brainApi.planInclude(nookId, message.id, i, e.currentTarget.checked)} />
        <span class="num">{i + 1}</span>
        <span>{step?.summary ?? action.tool}</span>
        {#if step?.tag}<span class="tag">{step.tag}</span>{/if}
      </label>
      <button class="ghost tiny" onclick={() => (open[i] = !open[i])}>{open[i] ? tr("Minder", "Less") : tr("Alle details", "All details")}</button>
      {#if label.text}<div class="result {label.cls}">{label.text}
        {#if message.actionStates[i]?.kind === "duplicate"}<button class="ghost tiny" onclick={() => brainApi.planRunAgain(nookId, message.id, i)}>{tr("Toch nog een keer", "Run again anyway")}</button>{/if}
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
                  <textarea rows="5" bind:value={editing[token]} use:focusField></textarea>
                {:else}
                  <input bind:value={editing[token]} use:focusField onkeydown={(e) => e.key === "Enter" && saveField(i, field.key)} />
                {/if}
                <button class="tiny" onclick={() => saveField(i, field.key)}>{tr("Klaar", "Done")}</button>
              {:else}
                <span class="value" class:multi={field.multiline}>{field.value}</span>
                {#if field.editable && editable && !finished(i)}
                  <button class="ghost tiny" onclick={() => (editing[token] = field.value)}>{tr("Aanpassen", "Edit")}</button>
                {/if}
              {/if}
            </div>
          {/each}
        </div>
      {/if}
    </div>
  {/each}
  {#if error}<p class="result bad">{error}</p>{/if}
  {#if (message.planState?.kind === "failed" || message.planState?.kind === "done") && outcomeShown}
    <div class="outcome {message.planState.kind === 'failed' ? 'bad' : 'ok'}">{message.planState.detail}</div>
  {/if}
  {#if editable}
    <div class="buttons">
      <button class="ghost" onclick={() => api.cancelPlan(nookId, message.id)}>{tr("Annuleer", "Cancel")}</button>
      <button class="primary" disabled={!included.some(Boolean) || blocked} title={blocked ? tr("Los eerst de problemen bij de stappen op", "Fix the problems in the steps first") : ""} onclick={run}>
        {planState === "failed" ? tr("Verder met de rest", "Continue with the rest") : tr("Uitvoeren", "Run")}{#if last}<kbd>Ctrl ↵</kbd>{/if}
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
  .buttons kbd { margin-left: 8px; font-size: 10px; opacity: 0.7; }
</style>
