<script lang="ts">
  // A small icon in its color on the title's line, the title, the lines under it, and a `trailing` slot (a tag, a
  // button, a check) (`IconDetailRow`). A `path` detail is cut in the middle so its file name stays.
  import type { Snippet } from "svelte";
  import { cutMiddle } from "../../lib/ui-parts";
  import Ico from "./Ico.svelte";
  let { icon, tint = "var(--text2)", title, detail, path, pathMax = 64, trailing }: {
    icon: string; tint?: string; title: string; detail?: string; path?: string; pathMax?: number; trailing?: Snippet;
  } = $props();
</script>

<div class="row">
  <span class="icon" style:color={tint}><Ico name={icon} size={13} stroke={2} /></span>
  <span class="text">
    <span class="title">{title}</span>
    {#if detail}<span class="detail">{detail}</span>{/if}
    {#if path}<span class="detail mono" title={path}>{cutMiddle(path, pathMax)}</span>{/if}
  </span>
  {#if trailing}<span class="trailing">{@render trailing()}</span>{/if}
</div>

<style>
  .row { display: flex; align-items: flex-start; gap: var(--space-8); min-width: 0; }
  .icon { display: inline-flex; padding-top: 3px; flex: none; }
  .text { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: var(--space-2); }
  .title { font: var(--text-control); color: var(--paper); }
  .detail { font: var(--text-detail); color: var(--text2); overflow-wrap: anywhere; }
  .mono { font-family: var(--mono); white-space: nowrap; overflow: hidden; }
  .trailing { flex: none; display: inline-flex; align-items: center; }
</style>
