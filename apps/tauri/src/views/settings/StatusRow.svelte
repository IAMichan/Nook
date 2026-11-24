<script lang="ts">
  // One state on a Settings page (`StatusRow`): an open circle while it still needs you, a mint check once it works,
  // its title and a line under it, and on the right what settles it.
  import type { Snippet } from "svelte";
  import Ico from "../../components/ui/Ico.svelte";
  let { title, detail = "", done = false, children }: { title: string; detail?: string; done?: boolean; children?: Snippet } = $props();
</script>

<div class="row status-row">
  <span class="state" class:done><Ico name={done ? "circle-check" : "circle"} size={18} stroke={1.5} /></span>
  <span class="text"><span class="title">{title}</span>{#if detail}<span class="detail">{detail}</span>{/if}</span>
  {@render children?.()}
</div>

<style>
  .status-row { flex-wrap: nowrap; justify-content: flex-start; gap: var(--space-16); }
  .status-row > .state:first-child { flex: none; display: grid; place-items: center; color: var(--text2); }
  .state.done { color: var(--mint); }
  .text { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 1px; }
  .title { font: var(--text-body); line-height: 1.3; color: var(--paper); }
  .detail { font: var(--text-detail); line-height: 1.3; color: var(--text2); }
</style>
