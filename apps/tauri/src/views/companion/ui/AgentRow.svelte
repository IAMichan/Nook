<script lang="ts">
  // One session on a shelf (`AgentRow`): the agent's logo, the title with its state or age in the corner, and the folder
  // and branch under it. Touch and hold for what you can do with it.
  import { age, needsYouState, type SessionDigest } from "../../../lib/companion";
  import AgentMark from "./AgentMark.svelte";
  import StatusPill from "../../../components/ui/StatusPill.svelte";
  import Ico from "../../../components/ui/Ico.svelte";
  let { session, onopen, onhold }: { session: SessionDigest; onopen: () => void; onhold?: (r: DOMRect) => void } = $props();
  const needs = $derived(session.items.length > 0 || needsYouState(session.attention));
  const pill = $derived(needs || session.attention === "working" || session.attention === "ready");
  let press: ReturnType<typeof setTimeout> | undefined;
  let held = false;
  let el = $state<HTMLButtonElement | null>(null);
  function down() {
    held = false;
    if (!onhold) return;
    press = setTimeout(() => { held = true; if (el) onhold?.(el.getBoundingClientRect()); }, 450);
  }
  const up = () => clearTimeout(press);
</script>

<button bind:this={el} class="row row-press" onclick={() => !held && onopen()} onpointerdown={down} onpointerup={up} onpointerleave={up} onpointercancel={up} onpointermove={(e) => { if (Math.abs(e.movementY) > 2) up(); }} oncontextmenu={(e) => e.preventDefault()}>
  <span class="logo"><AgentMark agent={session.agent} size={20} quiet={!needs && session.attention !== "working" && session.attention !== "ready"} /></span>
  <span class="body">
    <span class="l1">
      <strong class:needs>{session.title}</strong>
      {#if pill}<StatusPill attention={session.items[0]?.kind === "approval" ? "approval" : session.items[0]?.kind === "question" ? "input" : session.attention} />{:else}<span class="age">{age(session.updated)}</span>{/if}
    </span>
    <span class="meta">
      <Ico name="folder" size={11} stroke={2} /><span class="folder">{session.folder}</span>
      {#if session.branch && session.branch !== session.folder}<span>·</span><code>{session.branch}</code>{/if}
    </span>
  </span>
</button>

<style>
  .row { width: calc(100% - 16px); margin: 0 8px; display: flex; align-items: flex-start; gap: 10px; padding: 12px 10px; text-align: left; box-sizing: border-box; -webkit-touch-callout: none; user-select: none; }
  .logo { width: 22px; height: 22px; display: inline-flex; align-items: center; justify-content: center; padding-top: 1px; flex: none; }
  .body { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 4px; }
  .l1 { display: flex; align-items: baseline; gap: 8px; }
  strong { flex: 1; min-width: 0; font: var(--pt-strong); color: var(--text-strong); display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
  strong.needs { color: var(--paper); }
  .age { font: var(--pt-detail); color: var(--text3); flex: none; }
  .meta { display: flex; align-items: center; gap: 6px; font: var(--pt-detail); color: var(--text3); min-width: 0; }
  .folder { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; flex: none; max-width: 50%; }
  code { font: var(--pt-code); font-size: 13px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; min-width: 0; color: var(--text3); }
</style>
