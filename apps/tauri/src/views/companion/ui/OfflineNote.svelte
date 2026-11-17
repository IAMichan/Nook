<script lang="ts">
  // While the computer cannot be reached: one quiet line in place of what the phone did not keep (a chat or a
  // conversation it never saw), as the iPhone's `OfflineNote`.
  import type { Snippet } from "svelte";
  import Ico from "../../../components/ui/Ico.svelte";
  let { children }: { children: Snippet } = $props();
</script>

<div class="note"><Ico name="wifi-off" size={13} stroke={2.2} /><span>{@render children()}</span></div>

<style>
  .note { display: flex; align-items: baseline; gap: 6px; padding: 40px 4px; font: var(--pt-detail); color: var(--text3); animation: in 250ms ease-out 800ms backwards; }
  .note :global(svg) { position: relative; top: 2px; flex: none; }
  @keyframes in { from { opacity: 0; } }
</style>
