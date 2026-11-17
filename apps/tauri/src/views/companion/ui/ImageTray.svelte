<script lang="ts">
  // The pictures waiting in a composer (`ImageTray`): 56-point thumbnails, each with an x to take it out.
  import { tr } from "../../../lib/i18n.svelte";
  import Ico from "../../../components/ui/Ico.svelte";
  let { images, onremove }: { images: string[]; onremove: (i: number) => void } = $props();
</script>

{#if images.length}
  <div class="tray">
    {#each images as jpeg, i (i)}
      <span class="thumb">
        <img src="data:image/jpeg;base64,{jpeg}" alt="" />
        <button aria-label={tr("Foto verwijderen", "Remove picture")} onclick={() => onremove(i)}><Ico name="x" size={9} stroke={3.4} /></button>
      </span>
    {/each}
  </div>
{/if}

<style>
  .tray { display: flex; gap: 8px; padding: 6px 0 2px; }
  .thumb { position: relative; width: 56px; height: 56px; }
  img { width: 100%; height: 100%; object-fit: cover; border-radius: 8px; }
  button { position: absolute; top: -6px; right: -6px; width: 20px; height: 20px; border-radius: 50%; background: var(--smoke) !important; color: var(--paper) !important; display: inline-flex; align-items: center; justify-content: center; }
</style>
