<script lang="ts">
  // The Tauri app's composer: Nook's shared composer (packages/web-ui, the same one the browser extension uses) with
  // what only this app has: dropped documents read by Rust, drafts kept per Nook, a picture of the screen from the
  // bar, the microphone, and under the box the sources Nook may use and the brain that thinks.
  import { untrack } from "svelte";
  import SharedComposer from "@nook/web-ui/Composer.svelte";
  import type { ComposerMessage } from "@nook/web-ui/Composer.svelte";
  import { askedBefore } from "../lib/recall";
  import { drafts } from "../lib/drafts";
  import { barDraft, Draft } from "../lib/draft.svelte";
  import { nook } from "../lib/state.svelte";
  import { tr, locale } from "../lib/i18n.svelte";
  import { attachments } from "../lib/attachments.svelte";
  import { listening } from "../lib/listening.svelte";
  import { heard } from "./Orb.svelte";
  import MicButton from "./MicButton.svelte";
  import Listening from "../views/services/Listening.svelte";
  import SourcePicker from "./SourcePicker.svelte";
  import ChatAccounts from "../views/connectors/ChatAccounts.svelte";
  import BrainPicker from "./BrainPicker.svelte";

  let { autofocus = false, compact = false }: { autofocus?: boolean; compact?: boolean } = $props();
  // The bar's field keeps its draft when the panel closes; other fields keep theirs only while they are open.
  const ownDraft = new Draft();
  const draft = $derived(compact ? barDraft : ownDraft);
  let composer = $state<SharedComposer>();

  const history = $derived(askedBefore(nook.active?.messages ?? []));

  // Every Nook keeps what you were typing: switch away and back (or close the window) and it is still there. The bar
  // and the main window share it, so a question started in the bar can be finished in the window.
  let draftFor: string | null = null;
  $effect(() => {
    const id = nook.activeId;
    untrack(() => {
      if (id === draftFor) return;
      draftFor = id;
      draft.text = drafts.get(id);
    });
  });
  $effect(() => {
    const value = draft.text;
    untrack(() => drafts.set(draftFor, value));
  });

  export function focus() {
    composer?.focus();
  }

  // Een schermdeel komt als afbeelding bij het invoerveld van de balk.
  $effect(() => {
    if (!compact || !attachments.pending.length) return;
    for (const { mediaType, base64 } of attachments.take()) draft.addImage(mediaType, base64);
    composer?.focus();
  });

  async function send({ text, images, attachment }: ComposerMessage) {
    drafts.clear(draftFor);
    heard();
    const question = text || (attachment ? tr("Wat staat er in {name}?", "What is in {name}?", { name: attachment.name }) : tr("Wat staat er op deze afbeelding?", "What is in this image?"));
    await nook.ask(question, images.length ? images : undefined, attachment ?? undefined);
  }

  const texts = $derived({
    placeholder: tr("Vraag Nook iets…", "Ask Nook anything…"),
    placeholderFor: (name: string) => tr("Vraag iets over {name}…", "Ask about {name}…", { name }),
    field: tr("Bericht aan Nook", "Message Nook"),
    send: tr("Versturen (Enter)", "Send message (Enter)"),
    stop: tr("Antwoord stoppen", "Stop response"),
    attach: tr("Afbeeldingen of documenten bijvoegen", "Attach images or documents"),
    removeImage: tr("Afbeelding weghalen", "Remove image"),
    removeFile: tr("Weghalen", "Remove"),
    reading: tr("Document lezen…", "Reading document…"),
    characters: tr("tekens", "characters"),
  });
</script>

<div class="composer" class:compact>
  <SharedComposer
    bind:this={composer}
    {draft}
    {texts}
    {compact}
    {autofocus}
    {history}
    historyKey={nook.activeId}
    locale={locale()}
    busy={nook.busy}
    escapeStops={!compact}
    onsend={send}
    onstop={() => nook.stop()}
  >
    {#snippet top()}
      {#if listening.active}<Listening onclose={() => listening.stop()} />{/if}
    {/snippet}
    {#snippet extras()}
      <MicButton />
    {/snippet}
    {#snippet under()}
      {#if nook.info && !compact}
        <div class="under">
          <SourcePicker />
          <ChatAccounts nookId={nook.active?.id ?? null} ensure={() => nook.ensureActive()} />
          <BrainPicker />
        </div>
      {/if}
    {/snippet}
  </SharedComposer>
</div>

<style>
  /* The shared composer in this app's theme (app.css). */
  .composer {
    --nc-surface: var(--graphite);
    --nc-line: var(--line2);
    --nc-line-focus: color-mix(in srgb, var(--iris) 36%, var(--line2));
    --nc-text: var(--paper);
    --nc-faint: var(--text3);
    --nc-hover: var(--row-hover);
    --nc-accent: var(--iris);
    --nc-on-accent: var(--on-iris);
    --nc-accent-hover: color-mix(in srgb, var(--iris) 88%, var(--canvas));
    --nc-disabled: var(--line2);
    --nc-stop: var(--paper);
    --nc-on-stop: var(--canvas);
    --nc-error: var(--coral);
    --nc-shadow: 0 4px 24px #0002;
    --nc-pad: 12px;
    width: calc(100% - 64px);
    max-width: 760px;
    align-self: center;
    margin: 0 0 24px;
  }
  .composer.compact {
    --nc-radius: 0;
    --nc-shadow: none;
    width: 100%;
    max-width: none;
    margin: 0;
  }
  .composer.compact :global(.box) { border-width: 1px 0 0; border-color: var(--line); }
  .under { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; padding: 0 4px; min-width: 0; }
  @media (max-width: 640px) {
    .composer { width: calc(100% - 24px); margin-bottom: 12px; }
    .under { gap: 6px; }
  }
</style>
