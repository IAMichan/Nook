<script lang="ts">
  // Het invoerveld: Return verstuurt, Shift+Return is een nieuwe regel. Afbeeldingen plakken of slepen kan ook, en een
  // document (tekst, PDF, Word) slepen: Rust leest de tekst eruit en die gaat mee met je vraag.
  // Onder het veld: welke bronnen Nook mag gebruiken en welk brein denkt (klik om een ander lokaal model te kiezen).
  import { api } from "../lib/api";
  import { brainApi, fileBase64, type Attachment, type ServerModel } from "../lib/brain";
  import { nook } from "../lib/state.svelte";
  import { attachments } from "../lib/attachments.svelte";
  import { listening } from "../lib/listening.svelte";
  import { heard } from "./Orb.svelte";
  import Icon from "./Icon.svelte";
  import MicButton from "./MicButton.svelte";
  import Listening from "../views/services/Listening.svelte";
  import SourcePicker from "./SourcePicker.svelte";
  import ChatAccounts from "../views/connectors/ChatAccounts.svelte";

  let { autofocus = false, compact = false }: { autofocus?: boolean; compact?: boolean } = $props();
  let text = $state("");
  let images = $state<{ mediaType: string; base64: string; url: string }[]>([]);
  let attachment = $state<Attachment | null>(null);
  let reading = $state(false);
  let fileError = $state<string | null>(null);
  let dragging = $state(false);
  let brainMenu = $state(false);
  let servers = $state<ServerModel[]>([]);
  let field: HTMLTextAreaElement;
  let fileInput: HTMLInputElement;
  let brainRoot = $state<HTMLDivElement>();

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
    if ((!value && !attachment && !images.length) || nook.busy || reading) return;
    const attached = images.map(({ mediaType, base64 }) => ({ mediaType, base64 }));
    const file = attachment;
    text = "";
    images = [];
    heard();
    attachment = null;
    await nook.ask(value || (file ? `What is in ${file.name}?` : "What is in this image?"), attached.length ? attached : undefined, file ?? undefined);
  }

  function key(e: KeyboardEvent) {
    if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
      e.preventDefault();
      send();
    }
  }

  async function addFiles(files: FileList | File[]) {
    fileError = null;
    for (const file of Array.from(files)) {
      if (file.type.startsWith("image/")) {
        const base64 = await fileBase64(file);
        images = [...images, { mediaType: file.type, base64, url: `data:${file.type};base64,${base64}` }];
        continue;
      }
      reading = true;
      try {
        attachment = await brainApi.readAttachment(file.name, await fileBase64(file));
      } catch (e) {
        fileError = String(e);
      } finally {
        reading = false;
      }
    }
  }

  function paste(e: ClipboardEvent) {
    const files = Array.from(e.clipboardData?.files ?? []);
    if (files.length) addFiles(files);
  }

  async function openBrainMenu() {
    brainMenu = !brainMenu;
    if (brainMenu) servers = (await brainApi.advice()).servers;
  }

  async function chooseModel(m: ServerModel) {
    brainMenu = false;
    nook.settings = await brainApi.useLocal(m.server, m.name);
    nook.info = await api.appInfo();
  }

  function openBrainSettings() {
    brainMenu = false;
    localStorage.setItem("settings.section", "brain");
    api.showMain("settings");
  }
</script>

<svelte:window onclick={(e) => brainMenu && !brainRoot?.contains(e.target as Node) && (brainMenu = false)} />

<div
  class="composer"
  class:compact
  class:dragging
  role="group"
  ondragover={(e) => { e.preventDefault(); dragging = true; }}
  ondragleave={() => (dragging = false)}
  ondrop={(e) => {
    e.preventDefault();
    dragging = false;
    if (e.dataTransfer?.files) addFiles(e.dataTransfer.files);
  }}
>
  {#if listening.active}<Listening onclose={() => listening.stop()} />{/if}
  {#if images.length || attachment || reading}
    <div class="thumbs">
      {#each images as img, i (img.url)}
        <button class="thumb" title="Remove image" aria-label="Remove image" onclick={() => (images = images.filter((_, j) => j !== i))}>
          <img src={img.url} alt="" />
        </button>
      {/each}
      {#if reading}<span class="file faint">Document lezen…</span>{/if}
      {#if attachment}
        <button class="file" title="Weghalen" onclick={() => (attachment = null)}>
          📄 {attachment.name} <span class="faint">· {attachment.text.length.toLocaleString("nl-NL")} tekens ×</span>
        </button>
      {/if}
    </div>
  {/if}
  {#if fileError}<p class="err">{fileError}</p>{/if}
  <input class="file-input" type="file" multiple accept="image/*,.txt,.md,.csv,.json,.pdf,.docx" bind:this={fileInput} onchange={() => { if (fileInput.files) addFiles(fileInput.files); fileInput.value = ""; }} aria-label="Attach files" />
  <div class="row">
    <button class="ghost attach" onclick={() => fileInput.click()} title="Attach images or documents" aria-label="Attach images or documents" disabled={reading}><Icon name="attach" size={18} /></button>
    <textarea
      bind:this={field}
      bind:value={text}
      onkeydown={key}
      onpaste={paste}
      rows="1"
      aria-label="Message Nook"
      placeholder={attachment ? `Ask about ${attachment.name}…` : "Ask Nook anything…"}
    ></textarea>
    <MicButton />
    {#if nook.busy}
      <button class="ghost" onclick={() => nook.stop()} title="Stop response" aria-label="Stop response">■</button>
    {:else}
      <button class="primary" onclick={send} disabled={(!text.trim() && !attachment && !images.length) || reading} title="Send message (Enter)" aria-label="Send message"><Icon name="arrow" size={18} /></button>
    {/if}
  </div>
  {#if nook.info && !compact}
    <div class="under">
      <SourcePicker />
      <ChatAccounts nookId={nook.active?.id ?? null} ensure={() => nook.ensureActive()} />
      <div class="brain" bind:this={brainRoot}>
        <button class="chip" class:local={nook.info.brainLocal} class:off={!nook.info.brainReady} onclick={openBrainMenu}
          title={nook.info.brainLocal ? "Denkt op deze computer" : "Externe AI"}>
          {nook.info.brainLocal ? "● lokaal" : "○ extern"} · {nook.info.brainLabel}{nook.info.brainReady ? "" : " · niet klaar"}
        </button>
        {#if brainMenu}
          <div class="menu">
            {#each servers as m (m.server + m.name)}
              <button class="ghost item" onclick={() => chooseModel(m)}>{m.name} <span class="faint">{m.server === "ollama" ? "Ollama" : "LM Studio"}</span></button>
            {:else}
              <p class="faint item">Geen lokale modellen gevonden.</p>
            {/each}
            <div class="sep"></div>
            <button class="ghost item" onclick={openBrainSettings}>Brein-instellingen…</button>
          </div>
        {/if}
      </div>
    </div>
  {/if}
</div>

<style>
  .composer { width: calc(100% - 64px); max-width: 760px; align-self: center; margin: 0 0 24px; padding: 12px; border: 1px solid var(--line2); border-radius: 16px; background: var(--graphite); box-shadow: 0 4px 24px #0002; }
  .composer:focus-within { border-color: color-mix(in srgb, var(--iris) 36%, var(--line2)); }
  .file-input { display: none; }
  .composer.dragging { outline: 2px dashed var(--iris); outline-offset: -4px; }
  .composer.compact { padding: 8px 10px; width: 100%; max-width: none; margin: 0; border-radius: 0; border: 0; border-top: 1px solid var(--line); box-shadow: none; }
  .row { display: flex; gap: 8px; align-items: flex-end; }
  textarea {
    flex: 1;
    min-width: 0;
    resize: none;
    min-height: 36px;
    max-height: 140px;
    field-sizing: content;
    line-height: 1.6;
    background: transparent; border: 0; padding: 8px 2px; box-shadow: none;
  }
  .row :global(button) { flex-shrink: 0; width: 36px; height: 36px; padding: 0; font-size: 15px; }
  .under { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin-top: 10px; padding-top: 10px; border-top: 1px solid var(--line); min-width: 0; }
  .brain { position: relative; min-width: 0; margin-left: auto; max-width: 100%; }
  .chip { max-width: 100%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 11px; padding: 2px 8px; border-radius: 999px; background: none; color: var(--text3); }
  .chip.local { color: var(--text2); }
  .chip.off { color: var(--amber); }
  .menu { position: absolute; bottom: 32px; right: 0; max-width: min(320px, 80vw); box-shadow: var(--shadow-popover); z-index: 20; min-width: 220px; background: var(--smoke); border: 1px solid var(--line2); border-radius: 10px; padding: 6px; }
  .item { display: flex; justify-content: space-between; gap: 8px; width: 100%; text-align: left; font-size: 12px; padding: 4px 6px; margin: 0; }
  .sep { border-top: 1px solid var(--line2); margin: 4px 0; }
  .thumbs { display: flex; gap: 6px; margin-bottom: 8px; align-items: center; flex-wrap: wrap; }
  .thumb { padding: 0; width: 46px; height: 46px; overflow: hidden; border-radius: 8px; }
  .thumb img { width: 100%; height: 100%; object-fit: cover; }
  .file { max-width: 100%; overflow-wrap: anywhere; text-align: left; font-size: 12px; padding: 4px 10px; border-radius: 8px; }
  .err { color: var(--coral); font-size: 12px; margin: 0 0 6px; }
  textarea:focus-visible { box-shadow: none; }
  .row .attach { display: grid; place-items: center; }
  @media (max-width: 640px) {
    .composer { width: calc(100% - 24px); margin-bottom: 12px; padding: 8px; }
    .under { gap: 6px; }
    .brain { margin-left: 0; }
    .menu { left: 0; right: auto; }
  }
</style>
