<script lang="ts">
  // The clones running in the background (the Mac's `CloneNoticeStack`), each a quiet notice in the window's top right
  // corner: which repository, how far git is, and Hide and Cancel. Hide only takes the notice away; the clone goes on
  // and the composer that started it still gets the new folder.
  import { invoke } from "@tauri-apps/api/core";
  import { listen } from "@tauri-apps/api/event";
  import { tr } from "../../lib/i18n.svelte";
  import Ico from "../ui/Ico.svelte";

  interface CloneJob { id: number; url: string; name: string; progress: string | null; hidden: boolean; cancelling: boolean }

  let jobs = $state<CloneJob[]>([]);
  const shown = $derived(jobs.filter((j) => !j.hidden));

  $effect(() => {
    invoke<CloneJob[]>("clone_jobs").then((j) => (jobs = j)).catch(() => {});
    const un = listen<CloneJob[]>("clone-jobs", (e) => (jobs = e.payload));
    return () => { un.then((f) => f()).catch(() => {}); };
  });
</script>

{#if shown.length}
  <div class="clone-stack" role="status" aria-live="polite">
    {#each shown as job (job.id)}
      <div class="notice" title={job.url}>
        <span class="mark"><Ico name="circle-arrow-down" size={15} /></span>
        <div class="text">
          <span class="title">{tr("{name} klonen", "Cloning {name}", { name: job.name })}</span>
          <span class="detail">{job.cancelling ? tr("Stoppen…", "Cancelling…") : (job.progress ?? tr("Beginnen…", "Starting…"))}</span>
        </div>
        <div class="actions">
          <button class="ghost" onclick={() => invoke("clone_hide", { id: job.id })}>{tr("Verbergen", "Hide")}</button>
          <button class="ghost" disabled={job.cancelling} onclick={() => invoke("clone_cancel", { id: job.id })}>{tr("Annuleren", "Cancel")}</button>
        </div>
      </div>
    {/each}
  </div>
{/if}

<style>
  .clone-stack { position: fixed; top: calc(52px + var(--space-8)); right: var(--space-16); z-index: 45; display: flex; flex-direction: column; align-items: flex-end; gap: var(--space-8); pointer-events: none; }
  .notice {
    display: flex; align-items: center; gap: var(--space-8); width: 360px; max-width: calc(100vw - 32px); padding: var(--space-8) var(--space-8) var(--space-8) var(--space-12);
    background: var(--menu); border: 1px solid var(--line2); border-radius: var(--radius-card); box-shadow: var(--shadow-popover); pointer-events: auto;
    animation: rise var(--motion-reveal, 180ms) var(--ease-settle, ease-out);
  }
  .mark { display: inline-flex; color: var(--iris); flex: none; }
  .text { display: flex; flex-direction: column; gap: var(--space-2); flex: 1; min-width: 0; }
  .title { font: var(--text-emphasis); color: var(--paper); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .detail { font: var(--text-detail); color: var(--text2); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; font-variant-numeric: tabular-nums; }
  .actions { display: flex; gap: var(--space-4); flex: none; }
  .actions button { padding: var(--space-4) var(--space-8); border: 0; border-radius: var(--radius-control); font: var(--text-control); color: var(--text2); }
  .actions button:hover:not(:disabled) { background: var(--row-hover); color: var(--paper); }
  @keyframes rise { from { opacity: 0; transform: translateY(-4px); } }
  @media (prefers-reduced-motion: reduce) { .notice { animation: none; } }
</style>
