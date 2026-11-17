<script lang="ts">
  import { tr } from "../lib/i18n.svelte";
  // Eén bericht: boven het antwoord wat er opgezocht is, dan het antwoord zelf (Markdown), grafieken, mailconcepten,
  // het plan, de genummerde bronnen, meldingen en vervolgknoppen. Bij een fout de knop die hem oplost.
  import { openUrl } from "@tauri-apps/plugin-opener";
  import { api } from "../lib/api";
  import { brainApi, type Recovery } from "../lib/brain";
  import { renderMarkdown } from "../lib/markdown";
  import { visibleNotices } from "../lib/sources";
  import { nook } from "../lib/state.svelte";
  import { toast } from "../lib/toast.svelte";
  import type { ChatMessage } from "../lib/types";
  import TaskChecklist from "./TaskChecklist.svelte";
  import WorkingIndicator from "./WorkingIndicator.svelte";
  import { errorKind } from "../lib/working";
  import ChartView from "./ChartView.svelte";
  import MailDraftView from "./MailDraftView.svelte";
  import PlanCard from "./PlanCard.svelte";
  import SourcesView from "./SourcesView.svelte";

  let { message, nookId, last = false }: { message: ChatMessage; nookId: string; last?: boolean } = $props();
  const text = $derived(message.streaming ? (nook.streaming[message.id] ?? message.text ?? "") : message.text);
  const html = $derived(message.fromUser ? "" : renderMarkdown(text));
  const notices = $derived(message.streaming ? [] : visibleNotices(message));
  let enlargedImages = $state<Record<string, boolean>>({});

  function toggleImage(src: string) {
    enlargedImages[src] = !enlargedImages[src];
  }

  // The error card: what happened in plain words, by the fix it offers; the raw message behind Details.
  const failure = $derived(errorKind(message.recovery));
  let showDetails = $state(false);
  const explanation = $derived(
    failure.kind === "chooseModel"
      ? tr("Er is geen model beschikbaar. Kies er een en probeer het daarna opnieuw.", "No model is available. Choose one, then try again.")
      : failure.kind === "server"
        ? tr("{name} reageert niet. Open het programma en probeer het opnieuw.", "{name} is not responding. Open it and try again.", { name: failure.name })
        : failure.kind === "credentials"
          ? tr("De sleutel of inlog is geweigerd. Controleer die en probeer het opnieuw.", "The key or login was rejected. Check it and try again.")
          : tr("Er ging iets mis bij het maken van het antwoord. Probeer het opnieuw.", "Something went wrong while making the answer. Try again."),
  );

  let copied = $state(false);
  async function copyAnswer() {
    try {
      await navigator.clipboard.writeText(text);
      copied = true;
      setTimeout(() => (copied = false), 1500);
    } catch { /* The clipboard can be busy; the button simply stays. */ }
  }

  function click(e: MouseEvent) {
    const copy = (e.target as HTMLElement).closest("[data-copy-code]") as HTMLButtonElement | null;
    if (copy) {
      const code = copy.parentElement?.querySelector("pre code")?.textContent ?? "";
      navigator.clipboard.writeText(code).then(() => {
        copy.textContent = tr("Gekopieerd", "Copied");
        copy.classList.add("copied");
        setTimeout(() => { copy.textContent = tr("Kopieer", "Copy"); copy.classList.remove("copied"); }, 1500);
      }).catch(() => {});
      return;
    }
    const a = (e.target as HTMLElement).closest("a[data-external]") as HTMLAnchorElement | null;
    if (a) {
      e.preventDefault();
      openUrl(a.href);
    }
  }

  function recoveryTitle(r: Recovery): string {
    switch (r.kind) {
      case "chooseModel": return tr("Kies een model", "Choose a model");
      case "openLocalServer": return starting ? tr("{name} starten…", "Starting {name}…", { name: r.name }) : tr("Start {name} en probeer opnieuw", "Start {name} and retry", { name: r.name });
      case "reconnectBrain":
      case "reconnectConnection": return tr("Opnieuw koppelen", "Reconnect");
      default: return tr("Instellingen", "Settings");
    }
  }

  // A local brain that is installed but not running is started by Nook itself, and the question asked again. Only
  // when it is not installed does the button lead to the download page.
  let starting = $state(false);
  async function startLocal(name: string) {
    if (starting) return;
    starting = true;
    try {
      const outcome = await api.startLocalBrain(name);
      if (outcome === "notInstalled") {
        openUrl(name === "Ollama" ? "https://ollama.com/download" : "https://lmstudio.ai");
        return;
      }
      if (outcome === "noAnswer") return void toast.warning(tr("{name} start niet", "{name} does not start", { name }), tr("Hij is gestart maar antwoordt nog niet. Probeer het zo nog eens.", "It started but is not answering yet. Try again in a moment."));
      await brainApi.retryLast(nookId);
    } catch (e) {
      toast.error(tr("{name} kon niet starten", "{name} could not start", { name }), e);
    } finally {
      starting = false;
    }
  }

  function recover(r: Recovery) {
    if (r.kind === "openLocalServer") return void startLocal(r.name);
    localStorage.setItem("settings.section", r.kind === "reconnectConnection" ? "connections" : "brain");
    api.showMain("settings");
    window.dispatchEvent(new CustomEvent("nook-navigate", { detail: "settings" }));
  }
</script>

<div class="msg" class:user={message.fromUser} class:error={message.isError}>
  {#if message.fromUser}
    {#each message.images as src (src)}
      {@const label = enlargedImages[src] ? tr("Verkleinen", "Shrink") : tr("Vergroten", "Enlarge")}
      <button
        type="button"
        class="pic-btn"
        aria-pressed={!!enlargedImages[src]}
        aria-label={label}
        title={label}
        onclick={() => toggleImage(src)}
      >
        <img class="pic" class:enlarged={!!enlargedImages[src]} {src} alt="" />
      </button>
    {/each}
    {#if message.attachment}<div class="file">📄 {message.attachment}</div>{/if}
    <div class="bubble">{message.text}</div>
  {:else}
    <SourcesView {message} live={message.streaming} onRetry={last ? () => brainApi.retryLast(nookId) : undefined} />
    {#if message.tasks?.length}<TaskChecklist steps={message.tasks} live={message.streaming} />{/if}
    {#if message.isError && !message.streaming}
      <div class="error-card">
        <div class="error-head">
          <span class="mark">!</span>
          <div>
            <div class="error-title">{tr("Nook kan nu niet antwoorden", "Nook can't answer right now")}</div>
            <div class="error-detail">{explanation}</div>
          </div>
        </div>
        <div class="error-actions">
          <div class="offers">
            {#if message.recovery}<button class="primary" disabled={starting} onclick={() => recover(message.recovery!)}>{recoveryTitle(message.recovery)}</button>{/if}
            {#if last}<button class="ghost" onclick={() => brainApi.retryLast(nookId)}>{tr("Probeer opnieuw", "Try again")}</button>{/if}
          </div>
          <button class="ghost details" onclick={() => (showDetails = !showDetails)}>{showDetails ? tr("Verberg details", "Hide details") : tr("Details", "Details")}</button>
          {#if showDetails}<pre class="raw">{message.text}</pre>{/if}
        </div>
      </div>
    {:else if message.streaming && !text}
      <WorkingIndicator status={message.status} since={message.date} />
    {:else if text}
      <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
      <div class="markdown" onclick={click}>{@html html}</div>
      {#if !message.streaming && !message.isError}
        <div class="tools"><button class="ghost" onclick={copyAnswer} title={tr("Antwoord kopiëren", "Copy answer")} aria-label={tr("Antwoord kopiëren", "Copy answer")}>{copied ? tr("✓ Gekopieerd", "✓ Copied") : tr("Kopieer", "Copy")}</button></div>
      {/if}
    {/if}
    {#each message.charts ?? [] as chart (chart.id)}<ChartView {chart} />{/each}
    {#each message.mails ?? [] as draft (draft.id)}<MailDraftView {draft} {nookId} />{/each}
    {#if message.actions.length}
      <PlanCard {nookId} {message} {last} />
    {/if}
    {#if message.references.length && !message.streaming}
      <ol class="refs">
        {#each message.references as ref (ref.number)}
          <li value={ref.number}>
            {#if ref.url}<a href={ref.url} onclick={(e) => { e.preventDefault(); openUrl(ref.url!); }}>{ref.title}</a>{:else}{ref.title}{/if}
            {#if ref.detail}<span class="faint"> — {ref.detail}</span>{/if}
          </li>
        {/each}
      </ol>
    {/if}
    {#if notices.length}
      <div class="notices">
        {#each notices as notice (notice)}<div class="notice"><span class="mark">!</span><span>{notice}</span></div>{/each}
      </div>
    {/if}
    {#if message.streaming && text && message.status}
      <WorkingIndicator status={message.status} since={message.date} />
    {/if}
    {#if !message.isError && message.recovery}
      <div class="offers">
        {#if message.recovery}<button class:primary={message.recovery.kind === "openLocalServer"} disabled={starting} onclick={() => recover(message.recovery!)}>{recoveryTitle(message.recovery)}</button>{/if}
      </div>
    {/if}
    {#if message.offers.length && !message.streaming}
      <div class="offers">
        {#each message.offers as offer (offer)}
          <button onclick={() => nook.ask(offer)}>{offer}</button>
        {/each}
      </div>
    {/if}
  {/if}
</div>

<style>
  .msg { padding: 14px 0; max-width: 100%; line-height: 1.7; overflow-wrap: anywhere; }
  .msg.user { display: flex; flex-direction: column; align-items: flex-end; }
  .bubble { background: var(--smoke); border-radius: 14px 14px 4px 14px; padding: 12px 16px; max-width: 85%; white-space: pre-wrap; user-select: text; }
  .pic-btn { background: none; border: none; padding: 0; margin: 0 0 4px; display: inline-flex; max-width: 100%; border-radius: 10px; }
  .pic { display: block; max-width: 180px; max-height: 140px; border-radius: 10px; cursor: zoom-in; transition: max-width 0.2s ease, max-height 0.2s ease; }
  .pic.enlarged { width: auto; height: auto; min-width: min(100%, 240px); max-width: min(100%, 520px); max-height: 420px; object-fit: contain; cursor: zoom-out; }
  .file { font-size: 12px; color: var(--text2); margin-bottom: 4px; }
  .error .markdown { color: var(--coral); }
  .error-card { margin-top: 4px; padding: 14px; border-radius: 14px; background: color-mix(in srgb, var(--coral) 7%, transparent); }
  .error-head { display: flex; gap: 10px; align-items: flex-start; }
  .error-head .mark { color: var(--coral); font-weight: 600; width: 16px; text-align: center; }
  .error-title { font-weight: 600; }
  .error-detail { color: var(--text2); font-size: 13px; }
  .error-actions { padding-left: 26px; }
  .details { font-size: 12px; color: var(--text3); padding: 4px 0; margin-top: 6px; }
  .raw { font-size: 11.5px; color: var(--text3); white-space: pre-wrap; user-select: text; margin: 6px 0 0; padding: 10px; border-radius: 8px; background: var(--well, var(--smoke)); }
  .refs { margin: 8px 0 0; padding-left: 20px; font-size: 12px; color: var(--text2); }
  .notices { display: flex; flex-direction: column; gap: 8px; margin-top: 8px; padding: 8px 10px; border-radius: 12px; background: color-mix(in srgb, var(--amber) 6%, transparent); border: 1px solid color-mix(in srgb, var(--amber) 18%, transparent); }
  .notice { display: flex; gap: 8px; align-items: flex-start; font-size: 12px; color: var(--text2); user-select: text; }
  .mark { flex: none; width: 14px; height: 14px; margin-top: 1px; border-radius: 50%; background: var(--amber); color: var(--ink); font-size: 10px; font-weight: 700; display: grid; place-items: center; }
  .tools { display: flex; gap: 4px; margin-top: 2px; opacity: 0; transition: opacity 0.15s; }
  .msg:hover .tools, .tools:focus-within { opacity: 1; }
  .tools button { font-size: 11px; padding: 2px 8px; color: var(--text3); }
  .tools button:hover { color: var(--paper); }
  .offers { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 8px; }
  .offers button { font-size: 12px; padding: 4px 10px; border-radius: 999px; }
</style>
