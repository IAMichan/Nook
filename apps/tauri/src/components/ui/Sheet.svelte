<script lang="ts">
  // A sheet over the page (`.sheet`). On the desktop a Nook card in the middle of the window that Escape or a click
  // beside it closes; inside the companion (`.phone`) it slides up and leaves a strip of the tab showing at the top,
  // as on the iPhone (Settings, Pull requests, New session).
  import type { Snippet } from "svelte";
  import { onBack } from "../../lib/mobile";
  let { children, onclose, label, wide = false }: { children: Snippet; onclose: () => void; label?: string; wide?: boolean } = $props();
  $effect(() => onBack(() => (onclose(), true)));
  const keydown = (e: KeyboardEvent) => {
    if (e.key === "Escape") { e.stopPropagation(); onclose(); }
  };
</script>

<!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
<div class="dim" onclick={onclose}></div>
<!-- svelte-ignore a11y_no_static_element_interactions -->
<div class="sheet" class:wide role="dialog" aria-modal="true" aria-label={label} tabindex="-1" onkeydown={keydown}>{@render children()}</div>

<style>
  .dim { position: fixed; inset: 0; z-index: 40; background: rgba(0, 0, 0, 0.55); animation: fade 200ms ease-out; }
  .sheet { position: fixed; z-index: 41; left: 50%; top: 50%; transform: translate(-50%, -50%); width: min(560px, calc(100vw - 32px)); max-height: 90vh; border-radius: var(--radius-sheet); background: var(--graphite); border: 1px solid var(--line2); box-shadow: var(--shadow-popover); display: flex; flex-direction: column; overflow: hidden; outline: none; animation: pop 200ms cubic-bezier(0.2, 0.9, 0.3, 1.1); }
  .sheet.wide { width: min(680px, calc(100vw - 32px)); }
  :global(.phone) .dim { background: rgba(0, 0, 0, 0.5); animation-duration: 240ms; }
  :global(.phone) .sheet { left: 0; right: 0; bottom: 0; top: calc(var(--safe-top, 0px) + 10px); transform: none; width: auto; max-height: none; border: none; box-shadow: none; border-radius: 14px 14px 0 0; background: var(--canvas); animation: up 360ms cubic-bezier(0.2, 0.9, 0.25, 1); padding-bottom: var(--keyboard, 0px); }
  :global(.phone) .sheet::before { content: ""; position: absolute; top: 6px; left: 50%; width: 36px; height: 5px; margin-left: -18px; border-radius: 3px; background: var(--smoke); z-index: 2; }
  @keyframes up { from { transform: translateY(100%); } }
  @keyframes pop { from { opacity: 0; transform: translate(-50%, -50%) scale(0.97); } }
  @keyframes fade { from { opacity: 0; } }
</style>
