<!-- Where a scheduled run asked its question (`ScheduledRunMarker` on the Mac): a quiet line with the time instead of
     a bubble the user did not type, with the question itself one click away. -->
<script lang="ts">
  import Icon from "./Icon.svelte";
  import { locale, tr } from "../lib/i18n.svelte";

  let { text, date }: { text: string; date: string } = $props();
  let expanded = $state(false);
  const when = $derived(new Date(date).toLocaleString(locale(), { weekday: "short", hour: "2-digit", minute: "2-digit" }));
</script>

<div class="marker">
  <button class="line" aria-expanded={expanded} onclick={() => (expanded = !expanded)}>
    <span class="rule"></span>
    <span class="label"><Icon name="clock" size={11} />{tr("Geplande run · {when}", "Scheduled run · {when}", { when })}<Icon name={expanded ? "chevron-down" : "chevron-right"} size={10} /></span>
    <span class="rule"></span>
  </button>
  {#if expanded}<div class="question">{text}</div>{/if}
</div>

<style>
  .marker { display: flex; flex-direction: column; gap: var(--space-6); padding: var(--space-4) 0; }
  .line { all: unset; cursor: pointer; display: flex; align-items: center; gap: var(--space-8); }
  .line:focus-visible { outline: 2px solid var(--iris); outline-offset: 2px; border-radius: var(--radius-chip); }
  .rule { flex: 1; height: 1px; background: var(--line2); }
  .label { display: inline-flex; align-items: center; gap: var(--space-4); font: var(--text-label); color: var(--text3); white-space: nowrap; }
  .question { font: var(--text-detail); color: var(--text2); white-space: pre-wrap; user-select: text; padding: var(--space-8); border-radius: var(--radius-card); background: var(--field); }
</style>
