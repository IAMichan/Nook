<script lang="ts">
  // Een sessie die Nook zelf draait, in de tab Agents (`AgentRunPanel` op de Mac): het hele gesprek, toestemming,
  // stoppen, vervolgberichten en de keuzes voor de volgende beurt. Alles wat je anders in een terminal doet, gebeurt hier.
  import { agents } from "../../../lib/agents.svelte";
  import { projectName, workspaceApi, type RunEvent } from "../../../lib/workspace/api";
  import { workspace } from "../../../lib/workspace/store.svelte";
  import { oneLine } from "../../../lib/workspace/timeline";
  import ApprovalCard from "../ApprovalCard.svelte";
  import QuestionCard from "../QuestionCard.svelte";
  import Changes from "./Changes.svelte";
  import RunComposer from "./RunComposer.svelte";
  import Timeline from "./Timeline.svelte";

  let { runId, ongone }: { runId: string; ongone: () => void } = $props();

  let renaming = $state(false);
  let titleDraft = $state("");
  let revertTarget = $state<RunEvent | null>(null);
  let revertError = $state<string | null>(null);
  let reverting = $state(false);
  let confirmDelete = $state(false);
  let view = $state<"chat" | "changes">("chat");
  let changesFile = $state<string | null>(null);

  const run = $derived(workspace.run(runId));
  const events = $derived(workspace.timelines[runId] ?? []);
  const sessionKey = $derived(`run:${runId}`);
  const approvals = $derived(agents.approvals.filter((a) => a.sessionKey === sessionKey));
  const question = $derived(agents.questionFor(sessionKey));
  const fraction = $derived(run?.usage.contextWindow && run.usage.contextTokens ? run.usage.contextTokens / run.usage.contextWindow : 0);

  $effect(() => {
    void runId;
    workspace.loadTimeline(runId);
    if (workspace.run(runId)?.repoRoot) workspaceApi.git(runId, true).catch(() => {});
  });

  async function rename() {
    renaming = false;
    if (titleDraft.trim()) await workspace.act(() => workspaceApi.rename(runId, titleDraft.trim()));
  }

  async function askRevert(e: RunEvent) {
    revertError = null;
    const can = await workspaceApi.canRevert(runId, e.date).catch(() => false);
    revertTarget = e;
    if (!can) revertError = "Terugzetten kan alleen bij een sessie in een eigen worktree die niet bezig is.";
  }

  async function revert() {
    if (!revertTarget || reverting || revertError) return;
    reverting = true;
    try {
      await workspaceApi.revert(runId, revertTarget.date);
      revertTarget = null;
      agents.confirm("Bestanden teruggezet naar een eerder punt.");
    } catch (e) {
      revertError = String(e);
    }
    reverting = false;
  }

  async function remove() {
    confirmDelete = false;
    const done = await workspace.act(() => workspaceApi.remove(runId));
    if (done !== undefined) ongone();
  }

  async function implement(plan: string) {
    void plan;
    await workspace.act(async () => {
      await workspaceApi.configure(runId, { mode: "agent" });
      await workspaceApi.send(runId, "Voer het plan hierboven uit.");
    });
  }

  function openChanges(file: string | null = null) {
    workspaceApi.markReviewed(runId).catch(() => {});
    changesFile = file;
    view = "changes";
  }
</script>

{#if !run}
  <p class="faint">Deze sessie bestaat niet meer.</p>
{:else}
  <div class="panel">
    <header>
      <span class="project faint" title={run.workingDirectory}>{projectName(run.projectPath)}</span>
      <span class="faint">/</span>
      {#if renaming}
        <!-- svelte-ignore a11y_autofocus -->
        <input class="title-input" bind:value={titleDraft} placeholder="Naam van de sessie" autofocus
          onkeydown={(e) => { if (e.key === "Enter") rename(); if (e.key === "Escape") renaming = false; }} onblur={rename} />
      {:else}
        <button class="title" title="Dubbelklik om de naam te wijzigen" ondblclick={() => { titleDraft = run.title; renaming = true; }}>{run.title}</button>
      {/if}
      <span class="spacer"></span>
      {#if fraction > 0.6}
        <span class="ctx" class:crit={fraction > 0.85} title="Hoe vol het contextvenster zat bij de laatste modelaanroep">ctx {Math.round(fraction * 100)}%</span>
      {/if}
      {#if run.repoRoot}
        <button class="ghost branch" class:on={view === "changes"} title="Wijzigingen bekijken" onclick={() => (view === "changes" ? (view = "chat") : openChanges())}>
          ⑂ {run.branch ?? "geen branch"}{#if run.changedFiles} · {run.changedFiles}{/if}{#if run.lastChangeAt && (!run.reviewedAt || run.reviewedAt < run.lastChangeAt) && run.changedFiles}<span class="dot unread"></span>{/if}
        </button>
      {/if}
    </header>

    {#if view === "changes"}
      <Changes {run} file={changesFile} onclose={() => (view = "chat")} />
    {:else}
      <Timeline {run} {events} asking={!!question} onrevert={askRevert} onretry={() => workspace.act(() => workspaceApi.retry(runId))}
        onimplement={implement} openFile={(p) => openChanges(p)} />

      {#if approvals.length}
        <ApprovalCard approval={approvals[0]} others={approvals.length - 1} compact />
      {/if}

      {#if revertTarget}
        <div class="confirm amber">
          <div class="ctext">
            <strong>Bestanden terugzetten?</strong>
            <span class:err={!!revertError} class:faint={!revertError}>
              {revertError ?? `De bestanden in deze worktree gaan terug naar hoe ze waren vóór “${oneLine(revertTarget.text, 60)}”. Latere wijzigingen gaan verloren; het gesprek blijft.`}
            </span>
          </div>
          <button class="ghost" onclick={() => (revertTarget = null)}>Annuleer</button>
          <button class="primary" disabled={!!revertError || reverting} onclick={revert}>{reverting ? "Bezig…" : "Zet terug"}</button>
        </div>
      {:else if confirmDelete}
        <div class="confirm coral">
          <div class="ctext">
            <strong>"{run.title}" verwijderen?</strong>
            <span class="faint">Alleen uit Nook. Je map en bestanden blijven staan.</span>
          </div>
          <button class="ghost" onclick={() => (confirmDelete = false)}>Annuleer</button>
          <button class="primary" onclick={remove}>Verwijder</button>
        </div>
      {:else if question}
        {#key question.id}<QuestionCard request={question} />{/key}
      {:else}
        <RunComposer {run} onrename={() => { titleDraft = run.title; renaming = true; }} ondelete={() => (confirmDelete = true)} onchanges={() => openChanges()} />
      {/if}
    {/if}
  </div>
{/if}

<style>
  .panel { display: flex; flex-direction: column; gap: 10px; height: 100%; min-height: 0; }
  header { display: flex; align-items: center; gap: 8px; height: 30px; font-size: 13.5px; }
  .project { white-space: nowrap; }
  .title { background: none; border: none; padding: 0; font-weight: 600; color: var(--paper); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0; }
  .title:hover { background: none; }
  .title-input { flex: 1; padding: 3px 8px; }
  .spacer { flex: 1; }
  .ctx { font-family: var(--mono); font-size: 11px; color: var(--amber); }
  .ctx.crit { color: var(--coral); }
  .branch { font-size: 12px; display: inline-flex; gap: 6px; align-items: center; max-width: 45%; min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; flex-shrink: 1; }
  .branch.on { background: var(--smoke); color: var(--paper); }
  .confirm { display: flex; gap: 8px; align-items: center; padding: 12px; border-radius: 12px; }
  .confirm.amber { background: rgba(255, 184, 77, 0.08); }
  .confirm.coral { background: rgba(255, 107, 107, 0.08); }
  .ctext { flex: 1; display: flex; flex-direction: column; gap: 2px; font-size: 12px; }
  .ctext strong { font-size: 13px; }
  .err { color: #ff9b9b; }
</style>
