<script lang="ts">
  // Vandaag: je open punten (beloftes en taken die Nook bijhoudt).
  import { api } from "../lib/api";
  import type { OpenLoop } from "../lib/types";

  let loops = $state<OpenLoop[]>([]);
  const load = () => api.openLoops().then((l) => (loops = l));
  $effect(() => {
    load();
  });

  async function done(id: string) {
    await api.completeLoop(id);
    load();
  }
</script>

<section class="today">
  <h4>Open punten</h4>
  {#each loops as loop (loop.id)}
    <div class="loop">
      <button class="check" title="Afvinken" onclick={() => done(loop.id)}>○</button>
      <span>{loop.title}</span>
      {#if loop.due}<span class="faint">{new Date(loop.due).toLocaleString("nl-NL", { weekday: "short", hour: "2-digit", minute: "2-digit" })}</span>{/if}
    </div>
  {:else}
    <p class="faint">Niets open. Zeg bijvoorbeeld "onthoud dat ik Lisa terugbel".</p>
  {/each}
</section>

<style>
  .today { padding: 12px 16px; }
  h4 { margin: 0 0 8px; font-size: 12px; color: var(--text2); text-transform: uppercase; letter-spacing: 0.04em; }
  .loop { display: flex; gap: 8px; align-items: center; padding: 4px 0; }
  .loop span:nth-child(2) { flex: 1; }
  .check { padding: 0 6px; background: none; border: none; color: var(--text2); }
  .check:hover { color: var(--mint); background: none; }
</style>
