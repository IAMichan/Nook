<script lang="ts">
  // What Nook plans to do, drawn as the Mac's `PlanReview`: a title, the steps split by a hairline (a box to leave one
  // out, the app it acts on with its icon, what it does, a warning tag, the details on hover), and Run / Cancel under
  // them. Problems sit at the step and block Run; nothing happens until you click Run (or Ctrl+Enter on the newest
  // plan), and a step that went through never runs again. A plan that went through folds to one line.
  import { api } from "../lib/api";
  import { brainApi } from "../lib/brain";
  import type { ChatMessage, PlanStep, StepState } from "../lib/types";
  import { sourceDomain, sourceTitle } from "../lib/sources";
  import { tr } from "../lib/i18n.svelte";
  import ServiceIcon from "../views/connectors/ServiceIcon.svelte";
  import BusyLine from "./ui/BusyLine.svelte";
  import DisclosureChevron from "./ui/DisclosureChevron.svelte";
  import Ico from "./ui/Ico.svelte";
  import IconButton from "./ui/IconButton.svelte";
  import Spinner from "./ui/Spinner.svelte";
  import Tag from "./ui/Tag.svelte";

  let { nookId, message, last = false }: { nookId: string; message: ChatMessage; last?: boolean } = $props();
  let steps = $state<PlanStep[]>([]);
  let expanded = $state<Record<number, boolean>>({});
  let editing = $state<Record<number, boolean>>({});
  let drafts = $state<Record<string, string>>({});
  let showsSettledSteps = $state(false);
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

  const count = $derived(message.actions.length);
  const stepState = (i: number): StepState => message.actionStates[i] ?? { kind: "pending" };
  const included = (i: number) => message.actionIncluded[i] ?? true;
  const problems = (i: number) => message.actionProblems[i] ?? [];
  const canRun = (s: StepState) => s.kind === "pending" || s.kind === "failed";
  const planState = $derived(message.planState?.kind ?? "pending");
  /** Action remains to be taken: pending or after an error. */
  const open = $derived(planState === "pending" || planState === "failed");
  const runnable = $derived(message.actions.map((_, i) => i).filter((i) => included(i) && canRun(stepState(i))));
  const blocked = $derived(runnable.length === 0 || runnable.some((i) => problems(i).length > 0));
  const succeeded = $derived(message.actions.filter((_, i) => ["done", "verified"].includes(stepState(i).kind)).length);
  const finished = $derived(planState === "done" && succeeded > 0);
  const leftOut = (i: number) => ["skipped", "notRun"].includes(stepState(i).kind) || (stepState(i).kind === "pending" && !included(i));
  const leftOutCount = $derived(message.actions.filter((_, i) => leftOut(i)).length);
  const duplicates = $derived(message.actions.map((_, i) => i).filter((i) => stepState(i).kind === "duplicate"));
  const onlyRetries = $derived(runnable.every((i) => stepState(i).kind === "failed"));
  const header = $derived(count === 1 ? tr("VOORSTEL · CONTROLEER EN KEUR GOED", "PROPOSAL · REVIEW AND APPROVE") : tr("PLAN · {n} STAPPEN · CONTROLEER EN KEUR GOED", "PLAN · {n} STEPS · REVIEW AND APPROVE", { n: count }));
  const settledSummary = $derived(
    succeeded < count
      ? tr("{done} van {total} stappen uitgevoerd", "{done} of {total} steps done", { done: succeeded, total: count })
      : tr("{n} stappen uitgevoerd", "{n} steps done", { n: count }),
  );
  const failureHeadline = $derived(
    !message.actions.some((_, i) => ["failed", "duplicate"].includes(stepState(i).kind))
      ? null
      : succeeded === 0
        ? tr("Nog niets uitgevoerd; de reden staat hierboven.", "Nothing went through yet; the reason is shown above.")
        : tr("{done} van {total} stappen gelukt; wat nog openstaat zie je hierboven.", "{done} of {total} steps went through; what is left is shown above.", { done: succeeded, total: count }),
  );

  /** `ActionGate.splitSummary`: "WhatsApp → Anna: see you at 8" as where it goes and what it does. */
  function parts(i: number): { lead: string | null; body: string } {
    const step = steps[i];
    const text = (step?.summary ?? message.actions[i]?.tool ?? "").trim();
    const colon = text.indexOf(": ");
    const fallback = step?.source ? sourceTitle(step.source) || null : null;
    if (colon < 0) return { lead: fallback, body: text };
    const lead = text.slice(0, colon).trim();
    const body = text.slice(colon + 2).trim();
    if (!lead || !body || lead.length > 64 || lead.includes("\n")) return { lead: fallback, body: text };
    return { lead, body };
  }
  const sources = $derived([...new Set(steps.map((s) => s.source).filter((s): s is string => !!s))].slice(0, 4));

  function tagTint(tag: string): string {
    return /verwijder|remove|delete|vergeet|forget|vervang|replace|stuur|send|verstuur/i.test(tag) ? "var(--amber)" : "var(--text2)";
  }

  async function saveField(i: number, key: string) {
    const token = `${i}#${key}`;
    const value = drafts[token];
    delete drafts[token];
    if (value === undefined) return;
    try {
      await brainApi.planEdit(nookId, message.id, i, key, value);
      steps = await api.planSteps(nookId, message.id);
    } catch (e) {
      error = String(e);
    }
  }

  async function toggleEditing(i: number) {
    if (editing[i]) {
      for (const token of Object.keys(drafts).filter((t) => t.startsWith(`${i}#`))) await saveField(i, token.slice(token.indexOf("#") + 1));
    }
    editing[i] = !editing[i];
  }

  let running = false;
  async function run() {
    if (running) return;
    running = true;
    error = null;
    try {
      await api.executePlan(nookId, message.id, message.actions.map((_, i) => included(i)));
    } catch (e) {
      error = String(e);
    } finally {
      running = false;
    }
  }

  async function runAnyway() {
    for (const i of duplicates) await brainApi.planRunAgain(nookId, message.id, i).catch((e) => (error = String(e)));
  }

  /** Ctrl+Enter runs the newest plan that waits for you, without reaching for the mouse. */
  function runKey(e: KeyboardEvent) {
    if (!last || !open || blocked || running) return;
    if (e.key !== "Enter" || !(e.ctrlKey || e.metaKey) || e.shiftKey || e.altKey || e.isComposing || e.defaultPrevented) return;
    const target = e.target instanceof Element ? e.target : null;
    // Ctrl+Enter inside a field you are editing in the plan stays there.
    if (target?.closest(".plan textarea, .plan input")) return;
    e.preventDefault();
    run();
  }

  function focusField(node: HTMLInputElement | HTMLTextAreaElement) {
    node.focus();
  }
</script>

<svelte:window onkeydown={runKey} />

<div class="plan" class:folded={finished && !showsSettledSteps}>
  {#if finished}
    <button type="button" class="settled" aria-expanded={showsSettledSteps} aria-label={settledSummary} onclick={() => (showsSettledSteps = !showsSettledSteps)}>
      <span class="marker ok"><Ico name="circle-check" size={14} stroke={2.2} /></span>
      {#if count === 1}
        {@const p = parts(0)}
        {#if steps[0]?.source}<ServiceIcon domain={sourceDomain(steps[0].source)} title={p.lead ?? ""} size={13} />{/if}
        <span class="settled-text">{#if p.lead}<span class="lead-inline">{p.lead} · </span>{/if}{p.body}</span>
      {:else}
        <span class="settled-text">{settledSummary}</span>
        {#if leftOutCount}<span class="settled-skipped">{tr("{n} overgeslagen", "{n} skipped", { n: leftOutCount })}</span>{/if}
        <span class="stack" aria-hidden="true">
          {#each sources as source (source)}<span class="mini"><ServiceIcon domain={sourceDomain(source)} title={sourceTitle(source)} size={12} /></span>{/each}
        </span>
      {/if}
      <span class="grow"></span>
      <span class="vchev" class:open={showsSettledSteps}><Ico name="chevron-down" size={10} stroke={2.4} /></span>
    </button>
  {:else}
    <div class="header">{header}</div>
  {/if}

  {#if !finished || showsSettledSteps}
    <div class="steps">
      {#each message.actions as action, i (action.id)}
        {@const step = steps[i]}
        {@const p = parts(i)}
        {@const s = stepState(i)}
        {@const isOpen = !!expanded[i] || problems(i).length > 0}
        {@const warns = !!step?.tag && canRun(s) && open}
        {@const quiet = leftOut(i)}
        {@const canEdit = open && canRun(s)}
        <div class="step" class:open={isOpen}>
          <div class="row">
            <span class="marker">
              {#if s.kind === "done"}<span class="ok"><Ico name="circle-check" size={14} stroke={2.2} /></span>
              {:else if s.kind === "verified"}<span class="ok" title={tr("gecontroleerd", "confirmed")}><Ico name="badge-check" size={14} stroke={2.2} /></span>
              {:else if s.kind === "approved"}<span class="muted"><Ico name="clock" size={14} /></span>
              {:else if s.kind === "failed"}<span class="bad"><Ico name="circle-x" size={14} stroke={2.2} /></span>
              {:else if s.kind === "running"}<Spinner size={11} />
              {:else if s.kind === "duplicate"}<span class="warn"><Ico name="circle-alert" size={14} stroke={2.2} /></span>
              {:else if s.kind === "skipped" || s.kind === "notRun"}<span class="faint"><Ico name="circle-minus" size={14} /></span>
              {:else if open}
                <button type="button" class="box" class:on={included(i)} style:--tone={warns ? tagTint(step?.tag ?? "") : "var(--mint)"}
                  aria-pressed={included(i)}
                  title={included(i) ? tr("Deze stap overslaan", "Skip this step") : tr("Deze stap toch uitvoeren", "Include this step")}
                  onclick={() => brainApi.planInclude(nookId, message.id, i, !included(i))}>
                  <Ico name={included(i) ? "square-check" : "square"} size={14} stroke={2} />
                </button>
              {:else}
                <span class="num">{i + 1}</span>
              {/if}
            </span>
            <div class="content">
              {#if p.lead || warns}
                <div class="lead" class:quiet>
                  {#if p.lead}
                    {#if step?.source}<ServiceIcon domain={sourceDomain(step.source)} title={p.lead} size={13} />{/if}
                    <span class="lead-text">{p.lead}</span>
                  {/if}
                  {#if warns}<Tag text={step?.tag ?? ""} tint={tagTint(step?.tag ?? "")} />{/if}
                </div>
              {/if}
              <div class="body" class:quiet class:struck={open && !included(i)} class:clamp={!open && !isOpen}>{p.body}</div>
              {#if s.kind === "verified"}<div class="state ok">{tr("Uitgevoerd en gecontroleerd", "Done and confirmed")}</div>
              {:else if s.kind === "approved"}<div class="state">{tr("Goedgekeurd, wacht op zijn beurt", "Approved, waiting its turn")}</div>
              {:else if s.kind === "failed"}<div class="failure"><Ico name="triangle-alert" size={11} stroke={2.4} /><span>{s.detail ?? ""}</span></div>
              {:else if s.kind === "duplicate"}<div class="state warn">{tr("Al uitgevoerd op {when}; niet herhaald", "Already done on {when}; not repeated", { when: s.detail ?? "" })}</div>
              {:else if s.kind === "notRun"}<div class="state faint">{tr("Niet uitgevoerd (een eerdere stap mislukte)", "Not run (an earlier step failed)")}</div>
              {:else if s.kind === "skipped"}<div class="state faint">{tr("Overgeslagen", "Skipped")}</div>{/if}
            </div>
            <span class="details-toggle" class:shown={isOpen}>
              <IconButton size={20} title={tr("Alle details", "All details")} onclick={() => (expanded[i] = !expanded[i])}>
                <Ico name={isOpen ? "chevron-up" : "chevron-down"} size={12} />
              </IconButton>
            </span>
          </div>
          {#if isOpen}
            <div class="details">
              {#each step?.fields ?? [] as field (field.key)}
                {@const token = `${i}#${field.key}`}
                <div class="field">
                  <span class="field-label">{field.label}</span>
                  {#if editing[i] && field.editable && canEdit}
                    {#if field.multiline}
                      <textarea rows="5" value={drafts[token] ?? field.value} oninput={(e) => (drafts[token] = e.currentTarget.value)} onblur={() => saveField(i, field.key)}></textarea>
                    {:else}
                      <input value={drafts[token] ?? field.value} use:focusField oninput={(e) => (drafts[token] = e.currentTarget.value)} onblur={() => saveField(i, field.key)} onkeydown={(e) => e.key === "Enter" && saveField(i, field.key)} />
                    {/if}
                  {:else}
                    <span class="field-value" class:multi={field.multiline}>{field.value}</span>
                  {/if}
                </div>
              {/each}
              {#if (s.kind === "done" || s.kind === "verified") && s.detail}
                <div class="field">
                  <span class="field-label">{tr("Resultaat", "Result")}</span>
                  <span class="field-result">{s.detail}</span>
                </div>
              {/if}
              {#each problems(i) as problem (problem)}<div class="problem"><Ico name="triangle-alert" size={11} stroke={2.4} /><span>{problem}</span></div>{/each}
              {#if canEdit && (step?.fields ?? []).some((f) => f.editable)}
                <button type="button" class="ghost small" onclick={() => toggleEditing(i)}>{editing[i] ? tr("Klaar", "Done") : tr("Aanpassen", "Edit")}</button>
              {/if}
            </div>
          {/if}
        </div>
      {/each}
    </div>
  {/if}

  {#if error}<p class="problem">{error}</p>{/if}

  {#if !finished}
    <div class="controls">
      {#if planState === "pending"}
        <button type="button" class="primary small" disabled={blocked} title={blocked ? tr("Los eerst de problemen bij de stappen op", "Fix the problems in the steps first") : last ? "Ctrl+Enter" : ""} onclick={run}>
          <Ico name="check" size={12} stroke={2.6} />
          {runnable.length > 1 ? tr("Voer {n} stappen uit", "Run {n} steps", { n: runnable.length }) : tr("Uitvoeren", "Run")}
        </button>
        <button type="button" class="ghost small" onclick={() => api.cancelPlan(nookId, message.id)}>{tr("Annuleren", "Cancel")}</button>
      {:else if planState === "running"}
        <BusyLine text={tr("Bezig…", "Running…")} />
      {:else if planState === "done"}
        <span class="done-line"><Ico name="check" size={11} stroke={2.8} /><span>{message.planState?.detail ?? ""}</span></span>
      {:else if planState === "cancelled"}
        <span class="cancelled">{tr("Geannuleerd", "Cancelled")}</span>
      {:else if planState === "failed"}
        <div class="failed">
          <span class="failed-headline">{failureHeadline ?? message.planState?.detail ?? ""}</span>
          <div class="buttons">
            {#if runnable.length}
              <button type="button" class="primary small" disabled={blocked} onclick={run}>
                <Ico name="rotate-cw" size={12} stroke={2.4} />
                {onlyRetries ? tr("Opnieuw", "Retry") : tr("Verder met de rest", "Continue with the rest")}
              </button>
            {/if}
            {#if duplicates.length}<button type="button" class="ghost small" onclick={runAnyway}>{tr("Toch nog een keer", "Run again anyway")}</button>{/if}
            <button type="button" class="ghost small" onclick={() => api.cancelPlan(nookId, message.id)}>{tr("Stoppen", "Stop")}</button>
          </div>
        </div>
      {/if}
    </div>
  {/if}
</div>

<style>
  /* `PlanReview`: the field on the sheet's radius, 16 around (12 above and below once it folded to its line). */
  .plan { padding: var(--space-16); border-radius: var(--radius-sheet); background: var(--field); display: flex; flex-direction: column; gap: var(--space-8); }
  .plan.folded { padding: var(--space-12) var(--space-16); }
  .header { font: var(--text-emphasis); color: var(--paper); }
  .settled { all: unset; cursor: pointer; display: flex; align-items: center; gap: 9px; font: var(--text-body); color: var(--paper); min-width: 0; }
  .settled:focus-visible { outline: 2px solid var(--iris); outline-offset: 2px; border-radius: var(--radius-chip); }
  .settled-text { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; min-width: 0; }
  .lead-inline { color: var(--text2); }
  .settled-skipped { color: var(--text3); white-space: nowrap; }
  .stack { display: inline-flex; }
  .stack .mini { display: inline-flex; padding: 1.5px; border-radius: 50%; background: var(--graphite); border: 1px solid var(--field); margin-left: -4px; overflow: hidden; }
  .stack .mini:first-child { margin-left: 0; }
  .grow { flex: 1; }
  .vchev { display: inline-flex; color: var(--text3); transition: transform var(--motion-quick); }
  .vchev.open { transform: rotate(180deg); }
  .steps { display: flex; flex-direction: column; }
  .step { padding: var(--space-8) 0; display: flex; flex-direction: column; gap: var(--space-6); }
  /* `NookDivider(inset:)`: the hairline starts where the step's text does. */
  .step + .step { position: relative; }
  .step + .step::before { content: ""; position: absolute; top: 0; left: 27px; right: 0; border-top: 1px solid var(--separator); }
  .row { display: flex; align-items: flex-start; gap: 9px; }
  .marker { width: 18px; flex: none; display: inline-flex; justify-content: center; padding-top: 2px; color: var(--text3); }
  .ok { color: var(--mint); display: inline-flex; }
  .bad { color: var(--coral); display: inline-flex; }
  .warn { color: var(--amber); display: inline-flex; }
  .muted { color: var(--text2); display: inline-flex; }
  .faint { color: var(--text3); display: inline-flex; }
  .box { all: unset; cursor: pointer; display: inline-flex; color: var(--text3); border-radius: var(--radius-chip); }
  .box.on { color: var(--tone); }
  .box:focus-visible { outline: 2px solid var(--iris); outline-offset: 1px; }
  .num { width: 16px; height: 16px; border-radius: 50%; border: 1px solid var(--text3); font: var(--text-caption); color: var(--text2); display: inline-flex; align-items: center; justify-content: center; }
  .content { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: var(--space-4); }
  .lead { display: flex; align-items: center; gap: var(--space-6); min-width: 0; }
  .lead.quiet :global(.tile) { opacity: 0.5; }
  .lead-text { font: var(--text-label); color: var(--text2); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .lead.quiet .lead-text { color: var(--text3); }
  .body { font: var(--text-body); color: var(--paper); user-select: text; white-space: pre-wrap; overflow-wrap: anywhere; }
  .body.quiet { color: var(--text3); }
  .body.struck { text-decoration: line-through; }
  .body.clamp { display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
  .state { font: var(--text-detail); color: var(--text2); }
  .state.ok { color: var(--mint); }
  .state.warn { color: var(--amber); }
  .state.faint { color: var(--text3); }
  /* `StepFailure`: a quiet coral block instead of a wall of red. */
  .failure { margin-top: var(--space-4); display: flex; gap: var(--space-8); align-items: baseline; padding: var(--space-8) var(--space-12); border-radius: var(--radius-control); background: color-mix(in srgb, var(--coral) 8%, transparent); color: var(--coral); }
  .failure span { font: var(--text-label); color: var(--coral-soft); white-space: pre-wrap; user-select: text; }
  .details-toggle { opacity: 0; transition: opacity var(--motion-hover); }
  .step:hover .details-toggle, .details-toggle.shown, .details-toggle:focus-within { opacity: 1; }
  .details { margin-left: 27px; display: flex; flex-direction: column; gap: var(--space-8); align-items: flex-start; }
  .field { display: flex; flex-direction: column; gap: var(--space-2); width: 100%; }
  .field-label { font: var(--text-caption); color: var(--text3); }
  .field-value { font: var(--text-body); color: var(--paper); user-select: text; overflow-wrap: anywhere; }
  .field-value.multi { white-space: pre-wrap; }
  .field-result { font: var(--text-detail); color: var(--text2); user-select: text; white-space: pre-wrap; }
  .field input, .field textarea { font: var(--text-body); background: var(--graphite); border: none; padding: var(--space-8); width: 100%; box-sizing: border-box; }
  .problem { display: flex; gap: var(--space-6); align-items: baseline; margin: 0; font: var(--text-detail); color: var(--coral-soft); }
  .controls { display: flex; align-items: center; gap: var(--space-6); }
  button.small { display: inline-flex; align-items: center; gap: var(--space-6); height: 30px; padding: 0 var(--space-12); font: var(--text-emphasis); }
  button.primary.small { font-weight: 500; }
  .done-line { display: inline-flex; align-items: baseline; gap: var(--space-6); font: var(--text-body); color: var(--mint); }
  .cancelled { font: var(--text-body); color: var(--text3); }
  .failed { display: flex; flex-direction: column; gap: var(--space-8); }
  .failed-headline { font: var(--text-label); color: var(--text2); }
  .buttons { display: flex; gap: var(--space-6); }
</style>
