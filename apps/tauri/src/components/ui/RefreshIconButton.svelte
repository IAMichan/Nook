<script lang="ts">
  // Every refresh button (`RefreshIconButton`): the arrows turn while `turning`, so the button itself is the feedback;
  // never a spinner in its place. Without `turning` it turns while `onrefresh`'s promise runs, and always completes at
  // least one visible pulse (`RefreshPulse`, #1630) so quick/cached refreshes still confirm the click.
  import { onDestroy } from "svelte";
  import { tr } from "../../lib/i18n.svelte";
  import { RefreshPulse } from "../../lib/ui-parts";
  import IconButton from "./IconButton.svelte";
  import Ico from "./Ico.svelte";
  let {
    onrefresh,
    turning,
    title,
    disabled = false,
  }: { onrefresh: () => void | Promise<unknown>; turning?: boolean; title?: string; disabled?: boolean } = $props();
  let running = $state(false);
  let pulsing = $state(false);
  const pulse = new RefreshPulse((on) => (pulsing = on));
  onDestroy(() => pulse.stop());
  const spin = $derived((turning ?? running) || pulsing);

  async function refresh() {
    pulse.trigger();
    running = true;
    try { await onrefresh(); } finally { running = false; }
  }
</script>

<IconButton title={title ?? tr("Vernieuw", "Refresh")} onclick={refresh} disabled={disabled || (turning ?? running)}>
  <span class="nook-spin-glyph" class:nook-spin={spin}><Ico name="refresh-cw" size={13} stroke={2} /></span>
</IconButton>
