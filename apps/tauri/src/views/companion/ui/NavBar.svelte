<script lang="ts">
  // A pushed screen's bar (the iPhone's navigation bar): back on the left, a title in the middle, buttons on the right.
  import type { Snippet } from "svelte";
  import { tr } from "../../../lib/i18n.svelte";
  import Ico from "../../../components/ui/Ico.svelte";
  let { onback, center, trailing, tint }: { onback: () => void; center: Snippet; trailing?: Snippet; tint?: string } = $props();
</script>

<header style:background={tint}>
  <button class="back press" onclick={onback} aria-label={tr("Terug", "Back")}><Ico name="chevron-left" size={26} stroke={2.4} /></button>
  <div class="center">{@render center()}</div>
  <div class="trailing">{@render trailing?.()}</div>
</header>

<style>
  header { display: grid; grid-template-columns: 56px 1fr 56px; align-items: center; min-height: 52px; padding: 0 4px; background: rgba(0, 0, 0, 0.85); backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px); border-bottom: 0.5px solid var(--hairline); position: relative; z-index: 2; }
  .back { width: 44px; height: 44px; display: inline-flex; align-items: center; justify-content: center; color: var(--paper); }
  .center { min-width: 0; display: flex; justify-content: center; }
  .trailing { display: flex; justify-content: flex-end; }
</style>
