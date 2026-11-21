<script lang="ts">
  // A card in the bar (the Mac's notch `CardView`): Nook on the left in the card's color, what it says on the right. The
  // bar turns into it for a notice or a message, instead of opening the panel; the card's own content fills `children`.
  import type { Snippet } from "svelte";
  import Orb, { type Mood } from "../Orb.svelte";

  let { mood = "idle", tint, height = $bindable(0), children }: { mood?: Mood; tint?: string; height?: number; children: Snippet } = $props();
</script>

<div class="barcard" bind:clientHeight={height}>
  <div class="face"><Orb size={46} {mood} {tint} /></div>
  <div class="content">{@render children()}</div>
</div>

<style>
  .barcard { display: flex; gap: var(--space-16); padding: var(--space-24) var(--space-24) var(--space-16) var(--space-24); box-sizing: border-box; width: 100%; }
  .face { flex: none; padding-top: var(--space-2); }
  .content { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: var(--space-8); }
</style>
