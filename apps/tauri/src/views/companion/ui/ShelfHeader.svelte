<script lang="ts">
  // A shelf you fold (`NookShelfHeader`): its name, how many, and a chevron; open or closed is remembered.
  import Ico from "./Ico.svelte";
  let { title, count, open, ontoggle }: { title: string; count: number; open: boolean; ontoggle: () => void } = $props();
</script>

<button class="shelf press" onclick={ontoggle} aria-expanded={open}>
  <span class="title">{title}</span><span class="spacer"></span><span class="count">{count}</span>
  <span class="chev" class:closed={!open}><Ico name="chevron-down" size={12} stroke={2.4} /></span>
</button>

<style>
  .shelf { display: flex; align-items: center; gap: 8px; padding: 0 10px; min-height: 36px; margin: 8px 8px 0; width: calc(100% - 16px); box-sizing: border-box; }
  .title { font: var(--pt-label); color: var(--text2); }
  .spacer { flex: 1; }
  .count { font: var(--pt-detail); color: var(--text3); font-variant-numeric: tabular-nums; }
  .chev { color: var(--text3); width: 12px; display: inline-flex; transition: transform var(--reveal); }
  .chev.closed { transform: rotate(-90deg); }
</style>
