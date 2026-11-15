<script lang="ts">
  // "Add a picture" (the iPhone's photo button): a round button that opens the phone's picker; each picture is made a JPEG
  // small enough to travel (`CompanionImage`), at most two per message.
  import { MAX_IMAGES, shrinkToJpeg } from "../../../lib/images";
  import { tr } from "../../../lib/i18n.svelte";
  import Ico from "./Ico.svelte";
  let { count, onpick, ontoolarge }: { count: number; onpick: (jpegs: string[]) => void; ontoolarge: () => void } = $props();
  let input = $state<HTMLInputElement | null>(null);
  async function picked() {
    const files = [...(input?.files ?? [])].slice(0, MAX_IMAGES - count);
    if (input) input.value = "";
    const made: string[] = [];
    for (const f of files) {
      const jpeg = await shrinkToJpeg(f);
      if (jpeg) made.push(jpeg);
      else ontoolarge();
    }
    if (made.length) onpick(made);
  }
</script>

<button class="photo" aria-label={tr("Foto toevoegen", "Add a picture")} disabled={count >= MAX_IMAGES} onclick={() => input?.click()}><Ico name="image" size={15} stroke={2.2} /></button>
<input bind:this={input} type="file" accept="image/*" multiple hidden onchange={picked} />

<style>
  .photo { width: 34px; height: 34px; margin-bottom: 6px; border-radius: 50%; background: var(--smoke) !important; color: var(--text2) !important; display: inline-flex; align-items: center; justify-content: center; flex: none; }
</style>
