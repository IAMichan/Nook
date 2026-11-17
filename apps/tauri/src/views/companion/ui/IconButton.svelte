<script lang="ts">
  // A header's icon button (`NookIconButton`): 40×40, no fill, the glyph in text2.
  import Ico from "../../../components/ui/Ico.svelte";
  let { icon, label, onclick, disabled = false }: { icon: string; label: string; onclick: () => void; disabled?: boolean } = $props();
</script>

<button class="icon press" aria-label={label} title={label} {onclick} {disabled}><Ico name={icon} size={17} stroke={2.2} /></button>

<style>
  .icon { width: 40px; height: 40px; border-radius: 8px; display: inline-flex; align-items: center; justify-content: center; color: var(--text2); flex: none; }
</style>
