<script lang="ts">
  // De microfoonknop naast het invoerveld: praten tegen Nook. Alleen als dit platform een microfoon heeft.
  import { nook } from "../lib/state.svelte";
  import { listening } from "../lib/listening.svelte";
</script>

{#if nook.info?.capabilities.microphone}
  <button class="ghost mic" class:on={listening.active} title="Praten tegen Nook" aria-label="Praten tegen Nook" onclick={() => listening.toggle()}>🎙</button>
{/if}

<style>
  .mic { width: 36px; height: 36px; padding: 0; font-size: 15px; }
  .mic.on { color: var(--mint); }
</style>
