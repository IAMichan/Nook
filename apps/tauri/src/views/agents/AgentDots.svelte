<script lang="ts">
  // Een stipje per agentsessie in de dichte balk: amber wacht op je, wit is bezig, rood liep vast, groen is klaar en
  // nog niet bekeken. Wijs ernaar en de balk opent op de tab Agents.
  import { agents } from "../../lib/agents.svelte";
  import type { AgentSession } from "../../lib/agents";

  let { onhover }: { onhover: () => void } = $props();

  function unseen(s: AgentSession): boolean {
    if (s.status !== "done" || !s.updated) return false;
    const finished = new Date(s.updated).getTime();
    const visit = agents.overview?.marks.visits[s.id];
    if (visit) return finished > new Date(visit).getTime() + 1000;
    return Date.now() - finished < 24 * 3600 * 1000;
  }

  const dots = $derived(
    agents.sessions
      .filter((s) => s.status === "waiting" || s.status === "running" || s.status === "failed" || unseen(s))
      .slice(0, 8)
      .map((s) => ({ id: s.id, cls: s.approvalId || s.questionId || s.status === "waiting" ? "waiting" : s.status === "running" ? "working" : s.status === "failed" ? "error" : "unread", title: `${s.name} · ${s.project}` })),
  );
</script>

{#if dots.length}
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <span class="dots" onmouseenter={onhover}>
    {#each dots as d (d.id)}<span class="dot {d.cls}" title={d.title}></span>{/each}
  </span>
{/if}

<style>
  .dots { display: inline-flex; gap: 4px; align-items: center; padding: 4px; }
</style>
