<script lang="ts">
  // "Run workflow" on the Actions page, as on the Mac: start a workflow that has a
  // `workflow_dispatch` trigger, on a branch, with the inputs its file declares (read at the default branch). Only the
  // workflows that can be started by hand are offered; required inputs must be filled in before "Run" works. Starting
  // only happens after that click, and is written to the action log.
  import { untrack } from "svelte";
  import {
    actionsApi, dispatchable, dispatchDefaults, dispatchValues, missingInputs, type DispatchForm, type Dispatched,
  } from "../../../lib/actions";
  import { tr } from "../../../lib/i18n.svelte";

  let {
    repo, account, selected = null, onclose, ondispatched,
  }: {
    repo: string;
    account: string | null;
    /// The workflow chip that is selected on the page; picked first when it can be started by hand.
    selected?: number | null;
    onclose: () => void;
    ondispatched: (result: Dispatched, workflow: { id: number; name: string; branch: string }) => void;
  } = $props();

  let form = $state<DispatchForm | null>(null);
  let loadError = $state<string | null>(null);
  let workflowId = $state<number | null>(null);
  let branch = $state("");
  let values = $state<Record<string, string>>({});
  let sending = $state(false);
  let sendError = $state<string | null>(null);

  const startable = $derived(form ? dispatchable(form) : []);
  const chosen = $derived(startable.find((w) => w.id === workflowId) ?? null);
  const inputs = $derived(chosen?.inputs ?? []);
  const missing = $derived(missingInputs(inputs, values));

  $effect(() => {
    let cancelled = false;
    actionsApi
      .dispatchForm(untrack(() => account), repo)
      .then((f) => {
        if (cancelled) return;
        form = f;
        branch = f.defaultBranch || f.branches[0] || "";
        const list = dispatchable(f);
        choose(list.find((w) => w.id === untrack(() => selected))?.id ?? list[0]?.id ?? null);
      })
      .catch((e) => !cancelled && (loadError = String(e)));
    return () => (cancelled = true);
  });

  function choose(id: number | null) {
    workflowId = id;
    values = dispatchDefaults(form?.workflows.find((w) => w.id === id)?.inputs ?? []);
    sendError = null;
  }

  async function run() {
    if (!chosen || !branch || missing.length || sending) return;
    sending = true;
    sendError = null;
    try {
      const result = await actionsApi.dispatch(form?.account ?? account, repo, chosen.id, branch, dispatchValues(inputs, values));
      ondispatched(result, { id: chosen.id, name: chosen.name, branch });
    } catch (e) {
      sendError = String(e);
    } finally {
      sending = false;
    }
  }

  function keys(e: KeyboardEvent) {
    if (e.key === "Escape") onclose();
  }
</script>

<svelte:window onkeydown={keys} />

<div class="backdrop" role="presentation" onclick={(e) => e.target === e.currentTarget && onclose()}>
  <div class="sheet" role="dialog" aria-label={tr("Workflow starten", "Run workflow")}>
    <header>
      <h3>{tr("Workflow starten", "Run workflow")}</h3>
      <p class="muted">{repo}</p>
    </header>

    <div class="body">
      {#if loadError}
        <p class="bad">{loadError}</p>
      {:else if !form}
        <p class="muted">{tr("Workflows lezen…", "Reading workflows…")}</p>
      {:else if !startable.length}
        <p class="muted">
          {tr(
            "Geen van de workflows van deze repository kan met de hand starten. Een workflow heeft daarvoor de trigger workflow_dispatch nodig in zijn bestand.",
            "None of this repository's workflows can be started by hand. A workflow needs the workflow_dispatch trigger in its file for that.",
          )}
        </p>
      {:else}
        <label class="field">
          <span class="label">{tr("Workflow", "Workflow")}</span>
          <select value={workflowId} onchange={(e) => choose(Number(e.currentTarget.value))}>
            {#each startable as w (w.id)}<option value={w.id}>{w.name}</option>{/each}
          </select>
          {#if chosen}<span class="faint small mono">{chosen.path}</span>{/if}
        </label>

        <label class="field">
          <span class="label">{tr("Branch", "Branch")}</span>
          <select bind:value={branch}>
            {#each form.branches as b (b)}<option value={b}>{b}{b === form.defaultBranch ? tr(" (standaard)", " (default)") : ""}</option>{/each}
          </select>
        </label>

        {#each inputs as input (input.name)}
          {#if input.kind === "boolean"}
            <label class="check">
              <input type="checkbox" checked={values[input.name] === "true"} onchange={(e) => (values[input.name] = String(e.currentTarget.checked))} />
              <span class="text">
                <span>{input.description || input.name}</span>
                {#if input.description}<span class="faint small mono">{input.name}</span>{/if}
              </span>
            </label>
          {:else}
            <label class="field">
              <span class="label">{input.description || input.name}{#if input.required}<span class="faint"> *</span>{/if}</span>
              {#if input.kind === "choice" && input.options.length}
                <select bind:value={values[input.name]}>
                  {#each input.options as option (option)}<option value={option}>{option}</option>{/each}
                </select>
              {:else if input.kind === "number"}
                <input type="number" step="any" value={values[input.name] ?? ""} oninput={(e) => (values[input.name] = e.currentTarget.value)} />
              {:else}
                <input
                  bind:value={values[input.name]}
                  placeholder={input.kind === "environment" ? tr("Naam van de environment", "Environment name") : ""}
                  onkeydown={(e) => e.key === "Enter" && run()}
                />
              {/if}
              {#if input.description}<span class="faint small mono">{input.name}</span>{/if}
            </label>
          {/if}
        {/each}
      {/if}
      {#if sendError}<p class="bad">{sendError}</p>{/if}
    </div>

    <footer>
      {#if missing.length}
        <span class="faint small">{tr("Vul de verplichte velden in (*).", "Fill in the required fields (*).")}</span>
      {/if}
      <span class="spacer"></span>
      <button onclick={onclose}>{tr("Annuleer", "Cancel")}</button>
      <button class="primary" disabled={!chosen || !branch || missing.length > 0 || sending} onclick={run}>
        {sending ? tr("Starten…", "Starting…") : tr("Start", "Run")}
      </button>
    </footer>
  </div>
</div>

<style>
  .backdrop { position: fixed; inset: 0; background: rgba(0, 0, 0, 0.55); display: grid; place-items: center; z-index: 50; padding: 16px; }
  .sheet { background: var(--graphite); border: 1px solid var(--line2); border-radius: 18px; width: min(480px, 100%); max-height: 90vh; display: flex; flex-direction: column; overflow: hidden; }
  header { padding: 18px 20px 8px; }
  header h3 { margin: 0; font-size: 16px; }
  header p { margin: 2px 0 0; font-size: 12px; }
  .body { padding: 8px 20px 12px; overflow-y: auto; display: flex; flex-direction: column; gap: 12px; }
  .body p { margin: 0; font-size: 12.5px; }
  footer { display: flex; align-items: center; gap: 8px; padding: 12px 20px; border-top: 1px solid var(--line); flex-wrap: wrap; }
  .spacer { flex: 1; }
  .field { display: flex; flex-direction: column; gap: 4px; min-width: 0; }
  .field input, .field select { width: 100%; }
  .label { font-size: 12px; color: var(--text2); }
  .check { display: flex; align-items: flex-start; gap: 8px; font-size: 12.5px; }
  .check .text { display: flex; flex-direction: column; gap: 2px; }
  .small { font-size: 11px; }
  .mono { font-family: var(--mono); }
  .bad { color: var(--coral); user-select: text; }
</style>
