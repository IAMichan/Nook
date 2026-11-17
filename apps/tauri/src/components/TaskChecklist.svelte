<!-- The plan Nook works through (`update_plan`), as a live checklist above its answer (the Mac's `TaskChecklistCard`).
     A step left in progress after the answer stopped reads as still to do. Candidate for the shared components of
     FD-05 once agent sessions show their own task list. -->
<script lang="ts">
  import { tr } from "../lib/i18n.svelte";
  import { checklistProgress, type TaskStep } from "../lib/task-steps";

  let { steps, live }: { steps: TaskStep[]; live: boolean } = $props();
  let collapsed = $state(false);
  const shown = $derived(live ? steps : steps.map((s) => (s.status === "active" ? { ...s, status: "pending" as const } : s)));
  const progress = $derived(checklistProgress(shown));
</script>

<div class="checklist">
  <button
    type="button"
    class="head"
    aria-expanded={!collapsed}
    title={collapsed ? tr("Taken tonen", "Show tasks") : tr("Taken verbergen", "Hide tasks")}
    onclick={() => (collapsed = !collapsed)}
  >
    <span class="title">{tr("Taken", "Tasks")}</span>
    <span class="count">{tr("{done} van {total} klaar", "{done} of {total} done", { done: progress.done, total: progress.total })}</span>
    <span class="chevron" class:open={!collapsed} aria-hidden="true">›</span>
  </button>
  {#if !collapsed}
    <ul>
      {#each shown as step, i (i)}
        <li class={step.status}>
          <span class="mark" aria-hidden="true">
            {#if step.status === "done"}✓{:else if step.status === "cancelled"}×{:else if step.status === "active"}<span class="dot working"></span>{:else}○{/if}
          </span>
          <span class="text">{step.text}</span>
        </li>
      {/each}
    </ul>
  {/if}
</div>

<style>
  .checklist { margin: var(--space-6) 0; border: 1px solid var(--line2); border-radius: var(--radius-conversation-card); padding: var(--space-8) 12px; background: var(--field); }
  .head { all: unset; cursor: pointer; display: flex; align-items: baseline; gap: var(--space-8); width: 100%; color: var(--text2); }
  .title { font: var(--text-label); }
  .count { font: var(--text-detail); color: var(--text3); font-variant-numeric: tabular-nums; flex: 1; }
  .chevron { transition: transform 0.15s; }
  .chevron.open { transform: rotate(90deg); }
  ul { list-style: none; margin: var(--space-6) 0 0; padding: 0; display: flex; flex-direction: column; gap: var(--space-4); }
  li { display: flex; gap: var(--space-8); align-items: baseline; font: var(--text-detail); color: var(--text2); }
  .mark { width: 13px; text-align: center; flex: none; color: var(--text3); }
  li.done .mark { color: var(--mint); }
  li.active { color: var(--text-strong); }
  li.cancelled .text { text-decoration: line-through; color: var(--text3); }
  .dot { display: inline-block; width: 7px; height: 7px; border-radius: 50%; }
</style>
