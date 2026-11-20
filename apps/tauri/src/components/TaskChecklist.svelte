<!-- The plan Nook works through (`update_plan`), as a live checklist above its answer (the Mac's `TaskChecklistCard`).
     A step left in progress after the answer stopped reads as still to do. Candidate for the shared components of
     FD-05 once agent sessions show their own task list. -->
<script lang="ts">
  import { tr } from "../lib/i18n.svelte";
  import Ico from "./ui/Ico.svelte";
  import DisclosureChevron from "./ui/DisclosureChevron.svelte";
  import Spinner from "./ui/Spinner.svelte";
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
    aria-label={tr("Taken: {done} van {total} klaar", "Tasks: {done} of {total} done", { done: progress.done, total: progress.total })}
    onclick={() => (collapsed = !collapsed)}
  >
    <Ico name="list-checks" size={11} stroke={2.4} />
    <span class="title">{tr("Taken", "Tasks")}</span>
    <span class="count">{tr("{done} van {total} klaar", "{done} of {total} done", { done: progress.done, total: progress.total })}</span>
    <DisclosureChevron open={!collapsed} size={10} />
  </button>
  {#if !collapsed}
    <ul>
      {#each shown as step, i (i)}
        <li class={step.status}>
          <span class="mark" aria-hidden="true">
            {#if step.status === "done"}<Ico name="circle-check" size={13} stroke={2.2} />
            {:else if step.status === "cancelled"}<Ico name="circle-x" size={13} />
            {:else if step.status === "active"}<Spinner size={12} />
            {:else}<Ico name="circle-dashed" size={13} />{/if}
          </span>
          <span class="text">{step.text}</span>
        </li>
      {/each}
    </ul>
  {/if}
</div>

<style>
  /* `conversationCard(padding: lg)`: the field with its border and the conversation card's radius. */
  .checklist { margin: var(--space-6) 0; border: 1px solid var(--border); border-radius: var(--radius-conversation-card); padding: var(--space-12); background: var(--field); display: flex; flex-direction: column; gap: 7px; }
  .head { all: unset; cursor: pointer; display: flex; align-items: center; gap: 7px; width: 100%; color: var(--text2); }
  .head:focus-visible { outline: 2px solid var(--iris); outline-offset: 2px; border-radius: var(--radius-chip); }
  .title { font: var(--text-label); }
  .count { font: var(--text-detail); color: var(--text3); font-variant-numeric: tabular-nums; flex: 1; }
  ul { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: var(--space-6); }
  li { display: flex; gap: var(--space-8); align-items: center; font: var(--text-body); color: var(--text2); }
  li.done, li.cancelled { color: var(--text3); }
  .mark { width: 13px; height: 13px; display: inline-flex; align-items: center; justify-content: center; flex: none; color: var(--text3); }
  li.done .mark { color: var(--mint); }
  li.active { font: var(--text-emphasis); color: var(--paper); }
  li.active .mark { color: var(--paper); }
  li.cancelled .text { text-decoration: line-through; }
</style>
