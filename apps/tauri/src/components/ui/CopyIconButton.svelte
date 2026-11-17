<script lang="ts">
  // Every copy button (`CopyIconButton`): the symbol turns into a checkmark for 1.5 s, and a second click restarts the
  // moment. `text` is copied, or `oncopy` does the copying itself.
  import { tr } from "../../lib/i18n.svelte";
  import { CopiedMoment } from "../../lib/ui-parts";
  import IconButton from "./IconButton.svelte";
  import Ico from "./Ico.svelte";
  let { text, oncopy, title }: { text?: string; oncopy?: () => void | Promise<void>; title?: string } = $props();
  let copied = $state(false);
  const moment = new CopiedMoment((c) => (copied = c));
  $effect(() => () => moment.stop());

  async function copy() {
    try {
      if (oncopy) await oncopy();
      else if (text !== undefined) await navigator.clipboard.writeText(text);
      moment.copied();
    } catch {
      /* the clipboard said no; the icon stays a copy icon */
    }
  }
</script>

<IconButton title={copied ? tr("Gekopieerd", "Copied") : (title ?? tr("Kopieer", "Copy"))} onclick={copy}>
  <span class="glyph" class:copied><Ico name={copied ? "check" : "copy"} size={13} stroke={2} /></span>
</IconButton>

<style>
  .glyph { display: inline-flex; }
  .copied { color: var(--mint); }
</style>
