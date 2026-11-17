<script lang="ts">
  // The one way a picture is shown big (`ImageModal`): as large as the window allows on a dimmed backdrop with room
  // around it. A click or Escape closes it; `onopen` (optional) shows the file in the system's viewer.
  import { onBack } from "../../lib/mobile";
  import { tr } from "../../lib/i18n.svelte";
  import Ico from "./Ico.svelte";
  let { src, alt = "", onclose, onopen }: { src: string; alt?: string; onclose: () => void; onopen?: () => void } = $props();
  $effect(() => onBack(() => (onclose(), true)));
  $effect(() => {
    const esc = (e: KeyboardEvent) => { if (e.key === "Escape") { e.stopPropagation(); onclose(); } };
    window.addEventListener("keydown", esc, true);
    return () => window.removeEventListener("keydown", esc, true);
  });
</script>

<!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
<div class="stage" role="dialog" aria-modal="true" tabindex="-1" aria-label={alt || tr("Afbeelding", "Image")} onclick={onclose}>
  <img {src} {alt} />
  <div class="actions">
    {#if onopen}
      <button class="ghost" aria-label={tr("Open", "Open")} onclick={(e) => { e.stopPropagation(); onopen?.(); }}><Ico name="external-link" size={14} /></button>
    {/if}
    <button class="ghost" aria-label={tr("Sluit", "Close")} onclick={(e) => { e.stopPropagation(); onclose(); }}><Ico name="x" size={14} /></button>
  </div>
</div>

<style>
  .stage { position: fixed; inset: 0; z-index: 80; background: rgba(0, 0, 0, 0.82); display: flex; align-items: center; justify-content: center; padding: var(--space-48); cursor: zoom-out; animation: fade 160ms ease-out; }
  img { max-width: 100%; max-height: 100%; object-fit: contain; border-radius: var(--radius-card); box-shadow: var(--shadow-popover); animation: grow 200ms cubic-bezier(0.2, 0.9, 0.3, 1); }
  .actions { position: absolute; top: var(--space-12); right: var(--space-12); display: flex; gap: var(--space-4); }
  .actions button { width: 30px; height: 30px; padding: 0; display: inline-flex; align-items: center; justify-content: center; color: var(--paper); background: rgba(0, 0, 0, 0.4); }
  @keyframes fade { from { opacity: 0; } }
  @keyframes grow { from { transform: scale(0.96); opacity: 0; } }
  @media (prefers-reduced-motion: reduce) { .stage, img { animation: none; } }
</style>
