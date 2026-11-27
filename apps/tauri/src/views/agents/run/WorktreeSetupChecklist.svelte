<script lang="ts">
  // Live worktree setup checklist shown at the end of the timeline until the agent responds
  // (`WorktreeSetupChecklist.swift` on macOS, AG-94 / #1518).
  import { tr } from "../../../lib/i18n.svelte";
  import type { SetupStep, WorktreeSetupProgress } from "../../../lib/workspace/api";
  import { formatSetupDuration, SETUP_STEPS, setupFailure, setupStepState } from "../../../lib/workspace/worktree-setup";
  import Ico from "../../../components/ui/Ico.svelte";

  let {
    progress,
    active,
    oncancel,
  }: {
    progress: WorktreeSetupProgress;
    active: boolean;
    oncancel: () => void;
  } = $props();

  let showDetails = $state(false);
  let now = $state(Date.now());

  const failure = $derived(setupFailure(progress));
  const headline = $derived(
    failure
      ? tr("Worktree klaarzetten is mislukt", "Setting up the worktree failed")
      : !active
        ? tr("Worktree klaarzetten gestopt", "Worktree setup stopped")
        : tr("Worktree klaarzetten…", "Setting up worktree…"),
  );

  $effect(() => {
    if (!active) return;
    now = Date.now();
    const timer = setInterval(() => {
      now = Date.now();
    }, 1000);
    return () => clearInterval(timer);
  });

  function stepTitle(step: SetupStep): string {
    switch (step) {
      case "fetchBase":
        return tr("Basisbranch ophalen", "Fetch base branch");
      case "checkOut":
        return tr("Bestanden uitchecken", "Check out files");
      case "runSetup":
        return tr("Setup-script draaien", "Run setup script");
      case "startAgent":
        return tr("Agent starten", "Start agent");
    }
  }

  function runningElapsed(since: string): string {
    const start = Date.parse(since);
    if (!Number.isFinite(start)) return "";
    const elapsed = (now - start) / 1000;
    return elapsed >= 1 ? formatSetupDuration(Math.floor(elapsed)) : "";
  }
</script>

<div class="setup-checklist" role="region" aria-label={headline}>
  <div class="headline" class:failed={!!failure}>{headline}</div>
  <div class="divider" aria-hidden="true"></div>
  <div class="steps">
    {#each SETUP_STEPS as step (step)}
      {@const st = setupStepState(progress, step)}
      {@const pending = st.kind === "pending"}
      <div class="step-row">
        <span class="mark" class:pending class:failed={st.kind === "failed"} class:spinning={st.kind === "running" && active}>
          {#if st.kind === "done"}
            <Ico name="check" size={12} stroke={2.4} />
          {:else if st.kind === "skipped"}
            <Ico name="minus" size={12} stroke={2.4} />
          {:else if st.kind === "running"}
            {#if active}
              <Ico name="loader-circle" size={13} stroke={2.2} />
            {:else}
              <Ico name="x" size={12} stroke={2.4} />
            {/if}
          {:else if st.kind === "failed"}
            <Ico name="circle-x" size={13} stroke={2.2} />
          {:else}
            <Ico name="circle" size={13} stroke={1.8} />
          {/if}
        </span>
        <span class="title" class:pending>{stepTitle(step)}</span>
        <span class="trailing" class:failed={st.kind === "failed"}>
          {#if st.kind === "done"}
            {formatSetupDuration(st.seconds)}
          {:else if st.kind === "skipped"}
            {tr("overgeslagen", "skipped")}
          {:else if st.kind === "running"}
            {active ? runningElapsed(st.since) : tr("gestopt", "stopped")}
          {:else if st.kind === "failed"}
            {tr("mislukt", "failed")}
          {/if}
        </span>
      </div>
    {/each}
  </div>

  <div class="actions">
    <button type="button" class="plain" aria-expanded={showDetails} onclick={() => (showDetails = !showDetails)}>
      <Ico name={showDetails ? "chevron-down" : "chevron-right"} size={12} stroke={2.2} />
      <span>{tr("Details", "Details")}</span>
    </button>
    {#if active}
      <button type="button" class="plain" onclick={oncancel}>
        <Ico name="x" size={12} stroke={2.2} />
        <span>{tr("Annuleer", "Cancel")}</span>
      </button>
    {/if}
  </div>

  {#if showDetails}
    <div class="details">
      {#each progress.notes as note (note.id)}
        <p class="note">{note.text}</p>
      {/each}
      {#if failure}
        <p class="error-detail">{failure.message}</p>
      {/if}
    </div>
  {/if}
</div>

<style>
  .setup-checklist {
    display: flex;
    flex-direction: column;
    gap: var(--space-10);
    padding: var(--space-4) 0;
  }

  .headline {
    font-size: var(--text-body);
    color: var(--text2);
  }

  .headline.failed {
    color: var(--coral);
  }

  .divider {
    height: 1px;
    background: var(--line);
  }

  .steps {
    display: flex;
    flex-direction: column;
    gap: var(--space-8);
  }

  .step-row {
    display: flex;
    align-items: center;
    gap: var(--space-12);
  }

  .mark {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 16px;
    height: 16px;
    flex-shrink: 0;
    color: var(--paper);
  }

  .mark.pending {
    color: var(--text3);
  }

  .mark.failed {
    color: var(--coral);
  }

  .mark.spinning {
    animation: spin 1s linear infinite;
  }

  .title {
    font-size: var(--text-body);
    color: var(--paper);
    flex: 1;
    min-width: 0;
  }

  .title.pending {
    color: var(--text3);
  }

  .trailing {
    font-size: var(--text-detail);
    color: var(--text2);
    font-variant-numeric: tabular-nums;
    white-space: nowrap;
  }

  .trailing.failed {
    color: var(--coral);
  }

  .actions {
    display: flex;
    align-items: center;
    gap: var(--space-16);
    padding-left: var(--space-24);
  }

  .plain {
    display: inline-flex;
    align-items: center;
    gap: var(--space-6);
    background: none;
    border: none;
    padding: 0;
    font-size: var(--text-label);
    color: var(--text2);
    cursor: pointer;
  }

  .plain:hover {
    background: none;
    color: var(--paper);
  }

  .details {
    display: flex;
    flex-direction: column;
    gap: var(--space-4);
    padding-left: var(--space-24);
  }

  .note {
    margin: 0;
    font-size: var(--text-detail);
    color: var(--text3);
    user-select: text;
    white-space: pre-wrap;
    word-break: break-word;
  }

  .error-detail {
    margin: 0;
    font-size: var(--text-code);
    font-family: var(--mono);
    color: var(--coral);
    user-select: text;
    white-space: pre-wrap;
    word-break: break-word;
  }

  @keyframes spin {
    from {
      transform: rotate(0deg);
    }
    to {
      transform: rotate(360deg);
    }
  }
</style>
