<script lang="ts">
  // Het invoerveld: Return verstuurt, Shift+Return is een nieuwe regel. Afbeeldingen plakken of slepen kan ook.
  import { nook } from "../lib/state.svelte";
  import { attachments } from "../lib/attachments.svelte";
  import { listening } from "../lib/listening.svelte";
  import { heard } from "./Orb.svelte";
  import MicButton from "./MicButton.svelte";
  import Listening from "../views/services/Listening.svelte";

  let { autofocus = false, compact = false }: { autofocus?: boolean; compact?: boolean } = $props();
  let text = $state("");
  let images = $state<{ mediaType: string; base64: string; url: string }[]>([]);
  let field: HTMLTextAreaElement;

  export function focus() {
    field?.focus();
  }

  $effect(() => {
    if (autofocus) field?.focus();
  });

  // Een schermdeel komt als afbeelding bij het invoerveld van de balk.
  $effect(() => {
    if (!compact || !attachments.pending.length) return;
    const added = attachments.take().map(({ mediaType, base64 }) => ({ mediaType, base64, url: `data:${mediaType};base64,${base64}` }));
    images = [...images, ...added];
    field?.focus();
  });

  async function send() {
    const value = text.trim();
    if (!value || nook.busy) return;
    const attached = images.map(({ mediaType, base64 }) => ({ mediaType, base64 }));
    text = "";
    images = [];
    heard();
    await nook.ask(value, attached.length ? attached : undefined);
  }

  function key(e: KeyboardEvent) {
    if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
      e.preventDefault();
      send();
    }
  }

  function addFiles(files: FileList | File[]) {
    for (const file of Array.from(files)) {
      if (!file.type.startsWith("image/")) continue;
      const reader = new FileReader();
      reader.onload = () => {
        const url = String(reader.result);
        images = [...images, { mediaType: file.type, base64: url.split(",")[1] ?? "", url }];
      };
      reader.readAsDataURL(file);
    }
  }

  function paste(e: ClipboardEvent) {
    const files = Array.from(e.clipboardData?.files ?? []);
    if (files.length) addFiles(files);
  }
</script>

<div
  class="composer"
  class:compact
  role="group"
  ondragover={(e) => e.preventDefault()}
  ondrop={(e) => {
    e.preventDefault();
    if (e.dataTransfer?.files) addFiles(e.dataTransfer.files);
  }}
>
  {#if listening.active}<Listening onclose={() => listening.stop()} />{/if}
  {#if images.length}
    <div class="thumbs">
      {#each images as img, i (img.url)}
        <button class="thumb" title="Weghalen" onclick={() => (images = images.filter((_, j) => j !== i))}>
          <img src={img.url} alt="" />
        </button>
      {/each}
    </div>
  {/if}
  <div class="row">
    <textarea
      bind:this={field}
      bind:value={text}
      onkeydown={key}
      onpaste={paste}
      rows="1"
      placeholder="Vraag Nook iets…"
    ></textarea>
    <MicButton />
    {#if nook.busy}
      <button class="ghost" onclick={() => nook.stop()} title="Stoppen">■</button>
    {:else}
      <button class="primary" onclick={send} disabled={!text.trim()} title="Versturen (Return)">↑</button>
    {/if}
  </div>
  {#if nook.info && !compact}
    <div class="chip" class:local={nook.info.brainLocal} title={nook.info.brainLocal ? "Denkt op deze computer" : "Externe AI"}>
      {nook.info.brainLocal ? "● lokaal" : "○ extern"} · {nook.info.brainLabel}
    </div>
  {/if}
</div>

<style>
  .composer { padding: 10px 12px; border-top: 1px solid var(--line); background: var(--graphite); }
  .composer.compact { padding: 8px 10px; }
  .row { display: flex; gap: 8px; align-items: flex-end; }
  textarea {
    flex: 1;
    resize: none;
    min-height: 36px;
    max-height: 140px;
    field-sizing: content;
    line-height: 1.4;
  }
  .row button { width: 36px; height: 36px; padding: 0; font-size: 15px; }
  .chip { margin-top: 6px; font-size: 11px; color: var(--text3); }
  .chip.local { color: var(--text2); }
  .thumbs { display: flex; gap: 6px; margin-bottom: 8px; }
  .thumb { padding: 0; width: 46px; height: 46px; overflow: hidden; border-radius: 8px; }
  .thumb img { width: 100%; height: 100%; object-fit: cover; }
</style>
