<script lang="ts">
  // De microfoonknop naast het invoerveld: praten tegen Nook. Alleen als dit platform een microfoon heeft.
  import { nook } from "../lib/state.svelte";
  import { listening } from "../lib/listening.svelte";
  import Icon from "./Icon.svelte";
</script>

{#if nook.info?.capabilities.microphone}
  <button class="ghost mic" class:on={listening.active} aria-pressed={listening.active} title="Talk to Nook" aria-label="Talk to Nook" onclick={() => listening.toggle()}><Icon name="mic" size={18} /></button>
{/if}

<style>
  .mic { width: 36px; height: 36px; padding: 0; display: grid; place-items: center; }
  .mic.on { color: var(--mint); }
</style>
