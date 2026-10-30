<script lang="ts">
  // The shape of the run list (or a run's jobs) while its first answer is on its way, like `WorkflowRunGhostList` on
  // the Mac: grey bars where the mark, the title, the status and the line under it will be, so nothing jumps when the
  // rows come in. Quiet on purpose: no shimmer.
  import { tr } from "../../../lib/i18n.svelte";

  let { rows = 6, jobs = false }: { rows?: number; jobs?: boolean } = $props();
  // Title widths, so the rows do not look like one stamp repeated.
  const widths = [62, 48, 70, 40, 56, 50];
</script>

<div class="skeleton" role="status" aria-label={jobs ? tr("Jobs laden…", "Loading jobs…") : tr("Runs laden…", "Loading runs…")}>
  {#if !jobs}<span class="bar heading"></span>{/if}
  {#each Array.from({ length: rows }, (_, i) => widths[i % widths.length]) as width, i (i)}
    <div class="row" class:job={jobs}>
      <span class="dot"></span>
      <div class="text">
        <div class="line"><span class="bar" style:width="{width}%"></span><span class="bar status"></span></div>
        {#if !jobs}<div class="line"><span class="bar sub" style:width="{width * 0.7}%"></span><span class="bar time"></span></div>{/if}
      </div>
    </div>
  {/each}
</div>

<style>
  .skeleton { display: flex; flex-direction: column; gap: 2px; }
  .row { display: flex; align-items: flex-start; gap: 10px; padding: 10px; }
  .row.job { align-items: center; padding: 9px 10px; }
  .dot { width: 14px; height: 14px; border-radius: 50%; background: var(--smoke); flex: none; margin-top: 1px; }
  .text { display: flex; flex-direction: column; gap: 8px; flex: 1; min-width: 0; }
  .line { display: flex; align-items: center; gap: 8px; justify-content: space-between; }
  .bar { display: block; height: 10px; border-radius: 6px; background: var(--smoke); }
  .bar.sub { height: 7px; }
  .bar.status { width: 72px; height: 8px; flex: none; }
  .bar.time { width: 48px; height: 7px; flex: none; }
  .bar.heading { width: 64px; height: 9px; margin: 12px 10px 6px; }
</style>
