<script lang="ts">
  // The cross that closes a tab (`TabCloseButton`): a small bold × in a larger target, in the tab's own text color.
  // Hide it at rest with the `hover-reveal` class on a `hover-row` tab.
  import { tr } from "../../lib/i18n.svelte";
  import Ico from "./Ico.svelte";
  import { tip } from "./tip";
  let { onclose, title, class: klass = "" }: { onclose: () => void; title?: string; class?: string } = $props();
  const name = $derived(title ?? tr("Sluit", "Close"));
</script>

<button class="close {klass}" aria-label={name} use:tip={name} onclick={(e) => { e.stopPropagation(); onclose(); }}><Ico name="x" size={10} stroke={2.6} /></button>

<style>
  .close { display: inline-flex; align-items: center; justify-content: center; width: 18px; height: 18px; padding: 0; flex: none; background: transparent; border: none; border-radius: var(--radius-chip); color: inherit; opacity: 0.75; }
  .close:hover:not(:disabled) { opacity: 1; background: var(--smoke); }
</style>
