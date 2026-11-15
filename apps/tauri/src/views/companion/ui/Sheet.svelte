<script lang="ts">
  // A sheet over the tab (`.sheet`): Settings, Pull requests, New session. It slides up and leaves a strip of the
  // tab showing at the top, as on the iPhone.
  import type { Snippet } from "svelte";
  import { onBack } from "../../../lib/mobile";
  let { children, onclose }: { children: Snippet; onclose: () => void } = $props();
  $effect(() => onBack(() => (onclose(), true)));
</script>

<div class="dim"></div>
<div class="sheet phone" role="dialog" aria-modal="true">{@render children()}</div>

<style>
  .dim { position: fixed; inset: 0; z-index: 40; background: rgba(0, 0, 0, 0.5); animation: fade 240ms ease-out; }
  .sheet { position: fixed; left: 0; right: 0; bottom: 0; top: calc(var(--safe-top, 0px) + 10px); z-index: 41; border-radius: 14px 14px 0 0; background: var(--canvas); display: flex; flex-direction: column; overflow: hidden; animation: up 360ms cubic-bezier(0.2, 0.9, 0.25, 1); padding-bottom: var(--keyboard, 0px); }
  .sheet::before { content: ""; position: absolute; top: 6px; left: 50%; width: 36px; height: 5px; margin-left: -18px; border-radius: 3px; background: var(--smoke); z-index: 2; }
  @keyframes up { from { transform: translateY(100%); } }
  @keyframes fade { from { opacity: 0; } }
</style>
