<script lang="ts">
  // Every refresh button (`RefreshIconButton`): the arrows turn while `turning`, so the button itself is the feedback;
  // never a spinner in its place. Without `turning` it turns while `onrefresh`'s promise runs.
  import { tr } from "../../lib/i18n.svelte";
  import IconButton from "./IconButton.svelte";
  import Ico from "./Ico.svelte";
  let { onrefresh, turning, title }: { onrefresh: () => void | Promise<unknown>; turning?: boolean; title?: string } = $props();
  let running = $state(false);
  const spin = $derived(turning ?? running);

  async function refresh() {
    running = true;
    try { await onrefresh(); } finally { running = false; }
  }
</script>

<IconButton title={title ?? tr("Vernieuw", "Refresh")} onclick={refresh} disabled={spin}>
  <span class="glyph" class:spin><Ico name="refresh-cw" size={13} stroke={2} /></span>
</IconButton>

<style>
  .glyph { display: inline-flex; }
  .spin { animation: turn 0.9s linear infinite; }
  @keyframes turn { to { transform: rotate(360deg); } }
  @media (prefers-reduced-motion: reduce) { .spin { animation-duration: 2.7s; } }
</style>
