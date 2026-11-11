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
        copy.textContent = "Copied";
        copy.classList.add("copied");
        setTimeout(() => { copy.textContent = "Copy"; copy.classList.remove("copied"); }, 1500);
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
      case "openLocalServer": return starting ? tr(`${r.name} starten…`, `Starting ${r.name}…`) : tr(`Start ${r.name} en probeer opnieuw`, `Start ${r.name} and retry`);
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
      if (outcome === "noAnswer") return void toast.warning(`${name} start niet`, "Hij is gestart maar antwoordt nog niet. Probeer het zo nog eens.");
      await brainApi.retryLast(nookId);
    } catch (e) {
      toast.error(`${name} kon niet starten`, e);
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
    {#if message.streaming && !text}
      <div class="status"><span class="dot working"></span> {message.status || tr("Even nadenken…", "Thinking…")}</div>
    {:else if text}
      <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
      <div class="markdown" onclick={click}>{@html html}</div>
      {#if !message.streaming && !message.isError}
        <div class="tools"><button class="ghost" onclick={copyAnswer} title="Copy answer" aria-label="Copy answer">{copied ? "✓ Copied" : "Copy"}</button></div>
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
    {#if message.recovery || (message.isError && last)}
      <div class="offers">
        {#if message.recovery}<button class:primary={message.recovery.kind === "openLocalServer"} disabled={starting} onclick={() => recover(message.recovery!)}>{recoveryTitle(message.recovery)}</button>{/if}
        {#if last}<button class="ghost" onclick={() => brainApi.retryLast(nookId)}>{tr("Probeer opnieuw", "Try again")}</button>{/if}
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
  .status { color: var(--text2); display: flex; gap: 8px; align-items: center; }
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
