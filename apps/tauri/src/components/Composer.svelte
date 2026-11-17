<script lang="ts">
  // The Tauri app's composer: Nook's shared composer (packages/web-ui, the same one the browser extension uses) with
  // what only this app has: dropped documents read by Rust, drafts kept per Nook, a picture of the screen from the
  // bar, the microphone, and under the box the sources Nook may use and the brain that thinks.
  import { untrack } from "svelte";
  import { getCurrentWebview } from "@tauri-apps/api/webview";
  import { looksLikePath } from "../lib/paths";
  import SharedComposer from "@nook/web-ui/Composer.svelte";
  import type { ComposerMessage } from "@nook/web-ui/Composer.svelte";
  import { api } from "../lib/api";
  import { askedBefore } from "../lib/recall";
  import { drafts } from "../lib/drafts";
  import { brainApi, type ServerModel } from "../lib/brain";
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
  import QueuedTray from "./QueuedTray.svelte";

  let { autofocus = false, compact = false }: { autofocus?: boolean; compact?: boolean } = $props();
  // The bar's field keeps its draft when the panel closes; other fields keep theirs only while they are open.
  const ownDraft = new Draft();
  const draft = $derived(compact ? barDraft : ownDraft);
  let brainMenu = $state(false);
  let servers = $state<ServerModel[]>([]);
  let brainRoot = $state<HTMLDivElement>();
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

  const texts = $derived({
    placeholder: tr("Vraag Nook iets…", "Ask Nook anything…"),
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

<svelte:window onclick={(e) => brainMenu && !brainRoot?.contains(e.target as Node) && (brainMenu = false)} />

<div class="composer" class:compact onpastecapture={pastePath}>
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
    {#snippet under()}
      {#if nook.info && !compact}
        <div class="under">
          <SourcePicker />
          <ChatAccounts nookId={nook.active?.id ?? null} ensure={() => nook.ensureActive()} />
          <div class="brain" bind:this={brainRoot}>
            <button class="chip" class:local={nook.info.brainLocal} class:off={!nook.info.brainReady} onclick={openBrainMenu}
              title={nook.info.brainLocal ? tr("Denkt op deze computer", "Thinks on this computer") : tr("Externe AI", "External AI")}>
              {nook.info.brainLocal ? tr("● lokaal", "● local") : tr("○ extern", "○ external")} · {nook.info.brainLabel}{nook.info.brainReady ? "" : tr(" · niet klaar", " · not ready")}
            </button>
            {#if brainMenu}
              <div class="menu">
                {#each servers as m (m.server + m.name)}
                  <button class="ghost item" onclick={() => chooseModel(m)}>{m.name} <span class="faint">{m.server === "ollama" ? "Ollama" : "LM Studio"}</span></button>
                {:else}
                  <p class="faint item">{tr("Geen lokale modellen gevonden.", "No local models found.")}</p>
                {/each}
                <div class="sep"></div>
                <button class="ghost item" onclick={openBrainSettings}>{tr("Brein-instellingen…", "Brain settings…")}</button>
              </div>
            {/if}
          </div>
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
  .brain { position: relative; min-width: 0; margin-left: auto; max-width: 100%; }
  .chip { max-width: 100%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 11px; padding: 2px 8px; border-radius: 999px; background: none; color: var(--text3); }
  .chip.local { color: var(--text2); }
  .chip.off { color: var(--amber); }
  .menu { position: absolute; bottom: 32px; right: 0; max-width: min(320px, 80vw); box-shadow: var(--shadow-popover); z-index: 20; min-width: 220px; background: var(--smoke); border: 1px solid var(--line2); border-radius: 10px; padding: 6px; }
  .item { display: flex; justify-content: space-between; gap: 8px; width: 100%; text-align: left; font-size: 12px; padding: 4px 6px; margin: 0; }
  .sep { border-top: 1px solid var(--line2); margin: 4px 0; }
  @media (max-width: 640px) {
    .composer { width: calc(100% - 24px); margin-bottom: 12px; }
    .under { gap: 6px; }
    .brain { margin-left: 0; }
    .menu { left: 0; right: auto; }
  }
</style>
