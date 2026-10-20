<script lang="ts">
  // Eén bericht: boven het antwoord wat er opgezocht is, dan het antwoord zelf (Markdown), grafieken, mailconcepten,
  // het plan, de genummerde bronnen, meldingen en vervolgknoppen. Bij een fout de knop die hem oplost.
  import { openUrl } from "@tauri-apps/plugin-opener";
  import { api } from "../lib/api";
  import { brainApi, type Recovery } from "../lib/brain";
  import { renderMarkdown } from "../lib/markdown";
  import { visibleNotices } from "../lib/sources";
  import { nook } from "../lib/state.svelte";
  import type { ChatMessage } from "../lib/types";
  import ChartView from "./ChartView.svelte";
  import MailDraftView from "./MailDraftView.svelte";
  import PlanCard from "./PlanCard.svelte";
  import SourcesView from "./SourcesView.svelte";

  let { message, nookId, last = false }: { message: ChatMessage; nookId: string; last?: boolean } = $props();
  const text = $derived(message.streaming ? (nook.streaming[message.id] ?? message.text ?? "") : message.text);
  const html = $derived(message.fromUser ? "" : renderMarkdown(text));
  const notices = $derived(message.streaming ? [] : visibleNotices(message));

  function click(e: MouseEvent) {
    const a = (e.target as HTMLElement).closest("a[data-external]") as HTMLAnchorElement | null;
    if (a) {
      e.preventDefault();
      openUrl(a.href);
    }
  }

  function recoveryTitle(r: Recovery): string {
    switch (r.kind) {
      case "chooseModel": return "Kies een model";
      case "openLocalServer": return `Hoe start ik ${r.name}?`;
      case "reconnectBrain":
      case "reconnectConnection": return "Opnieuw koppelen";
      default: return "Instellingen";
    }
  }

  function recover(r: Recovery) {
    if (r.kind === "openLocalServer") {
      openUrl(r.name === "Ollama" ? "https://ollama.com/download" : "https://lmstudio.ai");
      return;
    }
    localStorage.setItem("settings.section", r.kind === "reconnectConnection" ? "connections" : "brain");
    api.showMain("settings");
    window.dispatchEvent(new CustomEvent("nook-navigate", { detail: "settings" }));
  }
</script>

<div class="msg" class:user={message.fromUser} class:error={message.isError}>
  {#if message.fromUser}
    {#each message.images as src (src)}<img class="pic" {src} alt="" />{/each}
    {#if message.attachment}<div class="file">📄 {message.attachment}</div>{/if}
    <div class="bubble">{message.text}</div>
  {:else}
    <SourcesView {message} live={message.streaming} onRetry={last ? () => brainApi.retryLast(nookId) : undefined} />
    {#if message.streaming && !text}
      <div class="status"><span class="dot working"></span> {message.status || "Even nadenken…"}</div>
    {:else if text}
      <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
      <div class="markdown" onclick={click}>{@html html}</div>
    {/if}
    {#each message.charts ?? [] as chart (chart.id)}<ChartView {chart} />{/each}
    {#each message.mails ?? [] as draft (draft.id)}<MailDraftView {draft} {nookId} />{/each}
    {#if message.actions.length}
      <PlanCard {nookId} {message} />
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
        {#if message.recovery}<button onclick={() => recover(message.recovery!)}>{recoveryTitle(message.recovery)}</button>{/if}
        {#if last}<button class="ghost" onclick={() => brainApi.retryLast(nookId)}>Probeer opnieuw</button>{/if}
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
  .msg { padding: 6px 0; max-width: 100%; }
  .msg.user { display: flex; flex-direction: column; align-items: flex-end; }
  .bubble { background: var(--smoke); border-radius: 14px 14px 4px 14px; padding: 8px 12px; max-width: 85%; white-space: pre-wrap; user-select: text; }
  .pic { max-width: 180px; max-height: 140px; border-radius: 10px; margin-bottom: 4px; }
  .file { font-size: 12px; color: var(--text2); margin-bottom: 4px; }
  .error .markdown { color: var(--coral); }
  .status { color: var(--text2); display: flex; gap: 8px; align-items: center; }
  .refs { margin: 8px 0 0; padding-left: 20px; font-size: 12px; color: var(--text2); }
  .notices { display: flex; flex-direction: column; gap: 8px; margin-top: 8px; padding: 8px 10px; border-radius: 12px; background: color-mix(in srgb, var(--amber) 6%, transparent); border: 1px solid color-mix(in srgb, var(--amber) 18%, transparent); }
  .notice { display: flex; gap: 8px; align-items: flex-start; font-size: 12px; color: var(--text2); user-select: text; }
  .mark { flex: none; width: 14px; height: 14px; margin-top: 1px; border-radius: 50%; background: var(--amber); color: var(--ink); font-size: 10px; font-weight: 700; display: grid; place-items: center; }
  .offers { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 8px; }
  .offers button { font-size: 12px; padding: 4px 10px; border-radius: 999px; }
</style>
