<script lang="ts" module>
  /** What a sent message holds: the words, the pictures, and a document read into text. */
  export interface ComposerMessage {
    text: string;
    images: { mediaType: string; base64: string }[];
    attachment: DraftDocument | null;
  }

  /** The composer's words, in the language of the surface it is on; each surface translates them its own way. */
  export interface ComposerTexts {
    placeholder: string;
    /** The placeholder while a document waits ("Ask about {name}…"). */
    placeholderFor?: (name: string) => string;
    field: string;
    send: string;
    stop: string;
    /** The queue button while Nook answers ("Queue: goes after this turn"); needed with `queues`. */
    queue?: string;
    attach: string;
    removeImage: string;
    /** The three below show only where documents can be attached (`Draft.readsDocuments`). */
    removeFile?: string;
    reading?: string;
    characters?: string;
  }
</script>

<script lang="ts">
  // The box you write to Nook in, as on the Mac (`SessionComposer`): the text on top, under it a row with attach, the
  // surface's own choices, and the round send button on the right, which turns into a stop button while Nook answers.
  // Return sends and Shift+Return is a new line. Up in an empty field brings back an earlier question. Pictures can be
  // pasted, dropped or picked; a document only where the surface can read one (`Draft`).
  //
  // One component for every web surface of Nook (the Tauri app for Windows, Linux and Android, and the browser
  // extension's side panel), so they look and work the same. A surface passes its colors as `--nc-*` variables and
  // adds its own parts through snippets: `top` above the box, `controls` after attach, `extras` before send, `under`
  // below the box.
  import type { Snippet } from "svelte";
  import type { Draft, DraftDocument } from "./draft.svelte";
  import { Recall } from "./recall";

  let {
    draft,
    texts,
    onsend,
    onstop,
    busy = false,
    queues = false,
    disabled = false,
    history = [],
    historyKey = null,
    escapeStops = false,
    compact = false,
    autofocus = false,
    locale,
    top,
    controls,
    extras,
    under,
  }: {
    draft: Draft;
    texts: ComposerTexts;
    onsend: (message: ComposerMessage) => void | Promise<void>;
    /** Stops Nook's answer. Without it, a busy composer only waits. */
    onstop?: () => void;
    /** Nook is answering: send waits (or becomes stop when `onstop` is given). */
    busy?: boolean;
    /** While busy, Return and the queue button still send: the message waits in line for after this answer. */
    queues?: boolean;
    /** Nothing can be sent at all (not connected): the field is read-only. */
    disabled?: boolean;
    /** Your earlier questions in this conversation, newest first (`askedBefore`). */
    history?: readonly string[];
    /** The conversation the history belongs to: a new one starts Up from the newest question again. */
    historyKey?: unknown;
    /** Escape stops the answer (in a window; in a bar Escape closes the bar). */
    escapeStops?: boolean;
    compact?: boolean;
    autofocus?: boolean;
    locale?: string;
    top?: Snippet;
    controls?: Snippet;
    extras?: Snippet;
    under?: Snippet;
  } = $props();

  let field = $state<HTMLTextAreaElement>();
  let fileInput = $state<HTMLInputElement>();
  let dragging = $state(false);
  const recall = new Recall();

  let recallFor: unknown = null;
  $effect(() => {
    if (historyKey !== recallFor) {
      recallFor = historyKey;
      recall.reset();
    }
  });

  $effect(() => {
    if (autofocus) field?.focus();
  });

  export function focus() {
    field?.focus();
  }

  const stoppable = $derived(busy && !!onstop);
  const canSend = $derived(!draft.empty && (!busy || queues) && !disabled && !draft.reading);

  async function send() {
    if (!canSend) return;
    const message: ComposerMessage = {
      text: draft.text.trim(),
      images: draft.images.map(({ mediaType, base64 }) => ({ mediaType, base64 })),
      attachment: draft.attachment,
    };
    draft.clear();
    recall.reset();
    await onsend(message);
  }

  function key(e: KeyboardEvent) {
    if (e.isComposing || !field) return;
    // Ctrl+Enter and Cmd+Enter belong to the surface (running a plan waiting for approval), not to the field.
    if (e.key === "Enter" && !e.shiftKey && !e.ctrlKey && !e.metaKey) {
      e.preventDefault();
      send();
    } else if ((e.key === "ArrowUp" || e.key === "ArrowDown") && !e.shiftKey && !e.altKey && !e.ctrlKey && !e.metaKey) {
      const up = e.key === "ArrowUp";
      const atStart = field.selectionStart === 0 && field.selectionEnd === 0;
      const atEnd = field.selectionStart === draft.text.length;
      const stepping = recall.stepping(history, draft.text);
      if (!(up ? atStart || !draft.text || stepping : atEnd || stepping)) return;
      const text = recall.step(history, draft.text, up ? 1 : -1);
      if (text === null) return;
      e.preventDefault();
      draft.text = text;
      queueMicrotask(() => field?.setSelectionRange(text.length, text.length));
    } else if (e.key === "Escape" && escapeStops && stoppable) {
      e.preventDefault();
      onstop?.();
    }
  }

  function pickFile() {
    draft.picking = true;
    fileInput?.click();
  }

  function picked() {
    draft.picking = false;
    if (fileInput?.files) draft.addFiles(fileInput.files);
    if (fileInput) fileInput.value = "";
  }

  function paste(e: ClipboardEvent) {
    const files = Array.from(e.clipboardData?.files ?? []);
    if (!files.length) return;
    // Text pastes itself; only files (a screenshot, a copied picture) are taken here.
    e.preventDefault();
    draft.addFiles(files);
  }

  const accept = $derived(draft.readsDocuments ? "image/*,.txt,.md,.csv,.json,.pdf,.docx,.odt,.pptx,.zip" : "image/*");
  const placeholder = $derived(draft.attachment && texts.placeholderFor ? texts.placeholderFor(draft.attachment.name) : texts.placeholder);
</script>

<div
  class="nook-composer"
  class:compact
  class:dragging
  role="group"
  ondragover={(e) => {
    if (disabled) return;
    e.preventDefault();
    dragging = e.dataTransfer?.types.includes("Files") ?? false;
  }}
  ondragleave={(e) => {
    if (!e.currentTarget.contains(e.relatedTarget as Node | null)) dragging = false;
  }}
  ondrop={(e) => {
    e.preventDefault();
    dragging = false;
    if (!disabled && e.dataTransfer?.files) draft.addFiles(e.dataTransfer.files);
  }}
>
  {@render top?.()}
  <div class="box">
    {#if draft.images.length || draft.attachment || draft.reading || dragging}
      <div class="thumbs">
        {#each draft.images as img, i (img.url)}
          <button type="button" class="thumb" title={texts.removeImage} aria-label={texts.removeImage} onclick={() => draft.removeImage(i)}>
            <img src={img.url} alt="" />
          </button>
        {/each}
        {#if draft.reading}<span class="file faint">{texts.reading}</span>{/if}
        {#if draft.attachment}
          <button type="button" class="file" title={texts.removeFile} onclick={() => (draft.attachment = null)}>
            {draft.attachment.name} <span class="faint">· {draft.attachment.text.length.toLocaleString(locale)} {texts.characters} ×</span>
          </button>
        {/if}
        {#if dragging}<span class="slot" aria-hidden="true">+</span>{/if}
      </div>
    {/if}
    {#if draft.fileError}<p class="err">{draft.fileError}</p>{/if}
    <textarea
      bind:this={field}
      bind:value={draft.text}
      onkeydown={key}
      onpaste={paste}
      oninput={() => recall.reset()}
      rows="1"
      {disabled}
      aria-label={texts.field}
      {placeholder}
    ></textarea>
    <div class="row">
      <input class="file-input" type="file" multiple {accept} bind:this={fileInput} onchange={picked} oncancel={() => (draft.picking = false)} aria-label={texts.attach} />
      <button type="button" class="icon" onclick={pickFile} title={texts.attach} aria-label={texts.attach} disabled={disabled || draft.reading}>
        <svg viewBox="0 0 24 24" aria-hidden="true"><path d="m8 13 7-7a3 3 0 0 1 4 4L9 20a5 5 0 0 1-7-7L12 3" /></svg>
      </button>
      {@render controls?.()}
      <span class="grow"></span>
      {@render extras?.()}
      {#if stoppable && queues && !draft.empty}
        <button type="button" class="round queue" onclick={send} disabled={!canSend} title={texts.queue} aria-label={texts.queue}>
          <svg viewBox="0 0 16 16" aria-hidden="true"><path d="M2.5 4h11M2.5 8h11M2.5 12h6M11 10.5v4M9 12.5h4" /></svg>
        </button>
      {/if}
      {#if stoppable}
        <button type="button" class="round stop" onclick={() => onstop?.()} title={texts.stop} aria-label={texts.stop}>
          <svg viewBox="0 0 16 16" aria-hidden="true"><rect x="4.5" y="4.5" width="7" height="7" rx="1.5" /></svg>
        </button>
      {:else}
        <button type="button" class="round send" onclick={send} disabled={!canSend} title={texts.send} aria-label={texts.send}>
          <svg viewBox="0 0 16 16" aria-hidden="true"><path d="M8 13V3.5M3.75 7.5 8 3.25l4.25 4.25" /></svg>
        </button>
      {/if}
    </div>
  </div>
  {@render under?.()}
</div>

<style>
  /* Every color comes from the surface (`--nc-*`); the fallbacks are Nook's own light theme. */
  .nook-composer { display: flex; flex-direction: column; gap: 8px; min-width: 0; }
  .box {
    display: flex;
    flex-direction: column;
    padding: var(--nc-pad, 10px 12px);
    border: 1px solid var(--nc-line, #e4e4e7);
    border-radius: var(--nc-radius, 16px);
    background: var(--nc-surface, #ffffff);
    box-shadow: var(--nc-shadow, none);
    transition: background-color 0.2s ease, border-color 0.2s ease;
  }
  .box:focus-within { background: var(--nc-surface-focus, var(--nc-surface, #ffffff)); border-color: var(--nc-line-focus, #d4d4d8); }
  .dragging .box { outline: 2px dashed var(--nc-accent, #1e1e22); outline-offset: -4px; }
  .compact .box { padding: 6px 8px; }
  textarea {
    width: 100%;
    box-sizing: border-box;
    min-height: 24px;
    max-height: 160px;
    field-sizing: content;
    resize: none;
    margin: 0;
    padding: 2px 2px 0;
    border: 0;
    outline: none;
    box-shadow: none;
    background: transparent;
    color: var(--nc-text, #27272a);
    font: inherit;
    line-height: 1.5;
  }
  textarea::placeholder { color: var(--nc-faint, #62626c); }
  textarea:focus-visible { box-shadow: none; outline: none; }
  textarea:disabled { cursor: default; }
  .row { display: flex; align-items: center; gap: 6px; margin: 6px 0 0 -4px; min-width: 0; }
  .grow { flex: 1; }
  .file-input { display: none; }
  button.icon, button.round {
    flex-shrink: 0;
    display: grid;
    place-items: center;
    margin: 0;
    padding: 0;
    border: 0;
    cursor: pointer;
  }
  button.icon {
    width: 32px;
    height: 32px;
    border-radius: var(--nc-control-radius, 8px);
    background: transparent;
    color: var(--nc-faint, #62626c);
  }
  button.icon:hover:not(:disabled) { background: var(--nc-hover, #f4f4f5); color: var(--nc-text, #27272a); }
  button.icon svg { width: 18px; height: 18px; fill: none; stroke: currentColor; stroke-width: 1.65; stroke-linecap: round; stroke-linejoin: round; }
  button.round { width: 32px; height: 32px; border-radius: 999px; }
  button.round svg { width: 16px; height: 16px; fill: none; stroke: currentColor; stroke-width: 1.75; stroke-linecap: round; stroke-linejoin: round; }
  button.send, button.queue { background: var(--nc-accent, #1e1e22); color: var(--nc-on-accent, #ffffff); }
  button.send:hover:not(:disabled), button.queue:hover:not(:disabled) { background: var(--nc-accent-hover, var(--nc-accent, #3b3b3f)); }
  button.send:disabled { background: var(--nc-disabled, #e4e4e7); color: var(--nc-faint, #62626c); cursor: default; }
  button.stop { background: var(--nc-stop, #18181b); color: var(--nc-on-stop, #fcfcfc); }
  button.stop svg { fill: currentColor; stroke: none; }
  button:disabled { cursor: default; opacity: 0.6; }
  button.send:disabled { opacity: 1; }
  button:focus-visible { outline: 2px solid var(--nc-accent, #1e1e22); outline-offset: 2px; }
  .thumbs { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; margin-bottom: 8px; }
  .thumb { width: 46px; height: 46px; padding: 0; overflow: hidden; border: 1px solid var(--nc-line, #e4e4e7); border-radius: 8px; background: none; cursor: pointer; }
  .thumb img { width: 100%; height: 100%; object-fit: cover; display: block; }
  .slot {
    display: grid;
    place-items: center;
    width: 46px;
    height: 46px;
    box-sizing: border-box;
    border: 1.5px dashed var(--nc-accent, #1e1e22);
    border-radius: 8px;
    color: var(--nc-accent, #1e1e22);
    background: color-mix(in srgb, var(--nc-accent, #1e1e22) 12%, transparent);
    font-size: 18px;
    pointer-events: none;
  }
  .file {
    max-width: 100%;
    overflow-wrap: anywhere;
    text-align: left;
    font: inherit;
    font-size: 12px;
    padding: 4px 10px;
    border: 1px solid var(--nc-line, #e4e4e7);
    border-radius: 8px;
    background: none;
    color: var(--nc-text, #27272a);
  }
  .faint { color: var(--nc-faint, #62626c); }
  .err { color: var(--nc-error, #c10007); font-size: 12px; margin: 0 0 6px; }
</style>
