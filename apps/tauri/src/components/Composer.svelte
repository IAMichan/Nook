<script lang="ts">
  // The Tauri app's composer: Nook's shared composer (packages/web-ui, the same one the browser extension uses) with
  // what only this app has: dropped documents read by Rust, drafts kept per Nook, a picture of the screen from the
  // bar, the microphone, and under the box the sources Nook may use and the brain that thinks.
  import { untrack } from "svelte";
  import { getCurrentWebview } from "@tauri-apps/api/webview";
  import { looksLikePath } from "../lib/paths";
  import SharedComposer from "@nook/web-ui/Composer.svelte";
  import type { ComposerMessage } from "@nook/web-ui/Composer.svelte";
  import { askedBefore } from "../lib/recall";
  import { drafts } from "../lib/drafts";
  import { barDraft, Draft } from "../lib/draft.svelte";
  import { api } from "../lib/api";
  import { nook } from "../lib/state.svelte";
  import { tr, locale } from "../lib/i18n.svelte";
  import { attachments } from "../lib/attachments.svelte";
  import { listening } from "../lib/listening.svelte";
  import { heard } from "./Orb.svelte";
  import MicButton from "./MicButton.svelte";
  import Listening from "../views/services/Listening.svelte";
  import SourcePicker from "./SourcePicker.svelte";
  import ChatAccounts from "../views/connectors/ChatAccounts.svelte";
  import QueuedTray from "./QueuedTray.svelte";
  import BrainPicker from "./BrainPicker.svelte";
  import Ico from "./ui/Ico.svelte";
  import { services } from "../lib/services";
  import { ACCESS_LEVELS, accessOf, nextAccess, type NookAccess } from "../lib/access";
  import Dropdown from "./ui/Dropdown.svelte";
  import DropdownRow from "./ui/DropdownRow.svelte";

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

  // A path pasted into the field is attached (a file, a zip archive or a folder); when it cannot be read, it is
  // pasted as the text it is.
  function pastePath(e: ClipboardEvent) {
    if (e.clipboardData?.files.length) return;
    const text = e.clipboardData?.getData("text/plain") ?? "";
    if (!looksLikePath(text)) return;
    e.preventDefault();
    e.stopPropagation();
    draft.addPath(text).catch(() => (draft.text += text));
  }

  // The main window keeps the system's own drag and drop: a file, zip archive or folder dropped on it arrives as a
  // path (the bar's field takes web drops, `Bar.svelte`).
  $effect(() => {
    if (compact) return;
    let stop: (() => void) | undefined;
    let gone = false;
    getCurrentWebview()
      .onDragDropEvent((event) => {
        if (event.payload.type !== "drop") return;
        for (const path of event.payload.paths) draft.addPath(path).catch((err) => (draft.fileError = String(err)));
      })
      .then((un) => (gone ? un() : (stop = un)))
      .catch(() => {});
    return () => {
      gone = true;
      stop?.();
    };
  });

  export function focus() {
    composer?.focus();
  }

  // A part of the screen arrives as an image at the bar's field, or at this one when its plus menu asked for it.
  let capturing = $state(false);
  function captureScreenPart() {
    capturing = true;
    attachments.start();
    services.partBegin().catch(() => (capturing = false));
  }
  $effect(() => {
    if (!(compact || capturing) || !attachments.pending.length) return;
    capturing = false;
    for (const { mediaType, base64 } of attachments.take()) draft.addImage(mediaType, base64);
    composer?.focus();
  });

  async function send({ text, images, attachment }: ComposerMessage) {
    drafts.clear(draftFor);
    heard();
    const question = text || (attachment ? tr("Wat staat er in {name}?", "What is in {name}?", { name: attachment.name }) : tr("Wat staat er op deze afbeelding?", "What is in this image?"));
    await nook.ask(question, images.length ? images : undefined, attachment ?? undefined);
  }

  // What Nook may do by itself (`brain::access`): the chip under the box, and Shift+Tab in the field, as in an
  // agent's composer.
  const access = $derived(nook.settings ? accessOf(nook.settings) : "ask");
  function accessLabel(level: NookAccess) {
    return level === "ask" ? tr("Eerst vragen", "Ask first") : level === "small" ? tr("Kleine dingen meteen", "Small things right away") : tr("Meer zelf doen", "More by itself");
  }
  function accessSymbol(level: NookAccess) {
    return level === "ask" ? "lock" : level === "small" ? "pointer" : "lock-open";
  }
  function accessDetail(level: NookAccess) {
    return level === "ask"
      ? tr("Elke actie wacht op je klik.", "Every action waits for your click.")
      : level === "small"
        ? tr("Muziek, volume, een app, een herinnering of een open punt gebeuren meteen als je erom vraagt.", "Music, volume, an app, a reminder, or a to-do happen at once when you ask for them.")
        : tr("Ook een afspraak zonder genodigden maken, een herinnering afvinken en een notitie. Een afspraak aanpassen, of een stap die betaalt, bestelt, verstuurt, verwijdert of boekt, vraagt nog steeds eerst.", "Also adding a calendar event without guests, ticking off a reminder, and a note. Changing an event, or a step that pays, orders, sends, deletes, or books, still asks first.");
  }
  function cycleAccess() {
    nook.saveSettings({ nookAccess: nextAccess(access) });
  }
  function accessKey(e: KeyboardEvent) {
    if (e.key === "Tab" && e.shiftKey && !e.altKey && !e.metaKey && !e.ctrlKey) {
      e.preventDefault();
      e.stopPropagation();
      cycleAccess();
    }
  }

  const texts = $derived({
    placeholder: nook.active?.messages.length ? tr("Vraag door of reageer…", "Ask a follow-up or reply…") : tr("Vraag Nook iets…", "Ask Nook anything…"),
    placeholderFor: (name: string) => tr("Vraag iets over {name}…", "Ask about {name}…", { name }),
    field: tr("Bericht aan Nook", "Message Nook"),
    send: tr("Versturen (Enter)", "Send message (Enter)"),
    stop: tr("Antwoord stoppen", "Stop response"),
    queue: tr("In de wachtrij: gaat na deze beurt", "Queue: goes after this turn"),
    attach: tr("Afbeeldingen of documenten bijvoegen", "Attach images or documents"),
    removeImage: tr("Afbeelding weghalen", "Remove image"),
    removeFile: tr("Weghalen", "Remove"),
    reading: tr("Document lezen…", "Reading document…"),
    characters: tr("tekens", "characters"),
  });
</script>

<div class="composer" class:compact onkeydowncapture={accessKey} onpastecapture={pastePath}>
  {#if nook.active?.queue?.messages.length}
    {@const id = nook.active.id}
    <QueuedTray
      queue={nook.active.queue}
      remove={(m) => api.queueRemove(id, m)}
      move={(m, to) => api.queueMove(id, m, to)}
      sendNow={(m) => api.queueSendNow(id, m)}
    />
  {/if}
  <SharedComposer
    bind:this={composer}
    rich={nook.settings?.richComposer !== false}
    {draft}
    {texts}
    {compact}
    {autofocus}
    {history}
    historyKey={nook.activeId}
    locale={locale()}
    busy={nook.busy}
    queues
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
    {#snippet plus({ pickFile, disabled })}
      {#if compact}
        <button type="button" class="plus-icon" onclick={pickFile} {disabled} title={texts.attach} aria-label={texts.attach}><Ico name="plus" size={14} stroke={2.4} /></button>
      {:else}
        <!-- The Mac's plus menu (`ComposerMoreMenu`): a file to add, or a part of the screen to ask about. -->
        <Dropdown width={300} label={tr("Meer opties", "More options")}>
          {#snippet trigger({ toggle, open })}
            <button type="button" class="plus-icon" class:lit={open} onclick={toggle} {disabled} title={tr("Meer opties", "More options")} aria-label={tr("Meer opties", "More options")} aria-expanded={open}><Ico name="plus" size={14} stroke={2.4} /></button>
          {/snippet}
          {#snippet children({ close })}
            <DropdownRow symbol="paperclip" title={tr("Bestand of map toevoegen", "Add a file or folder")} onclick={() => { close(); pickFile(); }} />
            <DropdownRow symbol="scan" title={tr("Vraag over een schermdeel", "Ask about a part of the screen")} onclick={() => { close(); captureScreenPart(); }} />
          {/snippet}
        </Dropdown>
      {/if}
    {/snippet}
    {#snippet controls()}
      <!-- The Mac's row of choices inside the box (`NookTab.composer`): the model, then what Nook may do by itself
           (Shift+Tab moves on) and the sources, split by a gap. -->
      {#if nook.info && !compact}
        <div class="choices">
          <BrainPicker />
          <span class="gap" aria-hidden="true"></span>
          <!-- What Nook may do by itself (the Mac's `NookAccessMenu`): the pill, and a panel with the three levels. -->
          <Dropdown width={320} label={tr("Wat Nook zelf mag", "What Nook may do")}>
            {#snippet trigger({ toggle, open })}
              <button class="composer-pill" class:more={access === "more"} onclick={toggle} aria-expanded={open}
                title={`${accessDetail(access)}\n${tr("⇧Tab voor het volgende niveau", "⇧Tab for the next level")}`}
                aria-label={tr("Wat Nook zelf mag", "What Nook may do")}>
                <Ico name={accessSymbol(access)} size={15} /><span>{accessLabel(access)}</span><Ico name="chevron-down" size={10} stroke={2.5} />
              </button>
            {/snippet}
            {#snippet children({ close })}
              <div class="dd-header">{tr("Wat Nook zelf mag", "What Nook may do")}</div>
              {#each ACCESS_LEVELS as level (level)}
                <DropdownRow symbol={accessSymbol(level)} title={accessLabel(level)} detail={accessDetail(level)} chosen={level === access}
                  tint={level === "more" ? "var(--coral-soft)" : undefined} onclick={() => { nook.saveSettings({ nookAccess: level }); close(); }} />
              {/each}
            {/snippet}
          </Dropdown>
          <span class="gap" aria-hidden="true"></span>
          <SourcePicker />
        </div>
      {/if}
    {/snippet}
    {#snippet under()}
      {#if nook.info && !compact}
        <div class="under"><ChatAccounts nookId={nook.active?.id ?? null} ensure={() => nook.ensureActive()} /></div>
      {/if}
    {/snippet}
  </SharedComposer>
</div>

<style>
  /* The shared composer in this app's theme (app.css). */
  .composer {
    /* The Mac's `SessionComposer`: one quiet surface with a hairline outline and a faint light along its top edge;
       focus only brightens the outline a little. */
    --nc-surface: var(--composer);
    --nc-line: var(--field-stroke);
    --nc-line-focus: color-mix(in srgb, var(--iris) 28%, transparent);
    --nc-text: var(--paper);
    --nc-faint: var(--text3);
    --nc-code: var(--smoke);
    --nc-hover: var(--row-hover);
    --nc-accent: var(--iris);
    --nc-on-accent: var(--on-iris);
    --nc-accent-hover: color-mix(in srgb, var(--iris) 88%, var(--canvas));
    --nc-disabled: var(--line2);
    --nc-stop: var(--paper);
    --nc-on-stop: var(--canvas);
    --nc-error: var(--coral);
    --nc-shadow: inset 0 1px 0 color-mix(in srgb, var(--paper) 6%, transparent);
    --nc-pad: var(--space-16) var(--space-8) var(--space-8) var(--space-16);
    --nc-row-margin: var(--space-8) 0 0 calc(-1 * var(--space-8));
    --nc-row-gap: var(--space-4);
    --nc-field-min: 20px;
    --nc-field-pad: 0;
    width: calc(100% - 2 * var(--space-24));
    max-width: var(--chat-column);
    align-self: center;
    margin: 0 0 var(--space-16);
  }
  .composer.compact {
    --nc-radius: 0;
    --nc-shadow: none;
    --nc-pad: 6px 8px;
    --nc-row-margin: 6px 0 0 -4px;
    --nc-field-pad: 2px 2px 0;
    width: 100%;
    max-width: none;
    margin: 0;
  }
  .composer.compact :global(.box) { border-width: 1px 0 0; border-color: var(--line); }
  .under { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; padding: 0 4px; min-width: 0; }
  .under:empty { display: none; }
  /* The plus as the Mac's `ComposerIcon`: a 26 pt square, quiet until hovered. */
  .plus-icon { display: grid; place-items: center; width: 26px; height: 26px; flex: none; padding: 0; margin: 0; border: 0; border-radius: var(--radius-control); background: transparent; color: var(--text2); }
  .plus-icon:hover:not(:disabled), .plus-icon.lit { background: var(--smoke); color: var(--paper); }
  .choices { display: flex; align-items: center; min-width: 0; }
  .gap { width: var(--space-4); flex: none; }
  /* A choice in the composer as the Mac's `ComposerPill`: its mark, its text and a small chevron, quiet until hovered. */
  .composer :global(.composer-pill) { display: inline-flex; align-items: center; gap: var(--space-6); height: 28px; min-width: 0; max-width: 100%; padding: 0 var(--space-8); margin: 0; border: 0; border-radius: var(--radius-control); background: transparent; color: var(--text2); font: var(--text-control); white-space: nowrap; }
  .composer :global(.composer-pill > span) { overflow: hidden; text-overflow: ellipsis; }
  .composer :global(.composer-pill > svg:last-child) { opacity: 0.6; }
  .composer :global(.composer-pill:hover), .composer :global(.composer-pill[aria-expanded="true"]) { background: var(--smoke); color: var(--paper); }
  .composer :global(.composer-pill.more) { color: var(--coral-soft); }
  @media (max-width: 640px) {
    .composer { width: calc(100% - 24px); margin-bottom: 12px; }
    .under { gap: 6px; }
    .composer :global(.composer-pill) { padding: 0 var(--space-6); }
  }
</style>
