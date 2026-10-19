<script lang="ts">
  import { renderMarkdown } from "../lib/markdown";
  import { nook } from "../lib/state.svelte";
  import { openUrl } from "@tauri-apps/plugin-opener";
  import type { ChatMessage } from "../lib/types";
  import PlanCard from "./PlanCard.svelte";

  let { message, nookId }: { message: ChatMessage; nookId: string } = $props();
  const text = $derived(message.streaming ? (nook.streaming[message.id] ?? "") : message.text);
  const html = $derived(message.fromUser ? "" : renderMarkdown(text));

  function click(e: MouseEvent) {
    const a = (e.target as HTMLElement).closest("a[data-external]") as HTMLAnchorElement | null;
    if (a) {
      e.preventDefault();
      openUrl(a.href);
    }
  }
</script>

<div class="msg" class:user={message.fromUser} class:error={message.isError}>
  {#if message.fromUser}
    {#each message.images as src (src)}<img class="pic" {src} alt="" />{/each}
    <div class="bubble">{message.text}</div>
  {:else}
    {#if message.sources.length}<div class="looked faint">Nook keek in {message.sources.join(", ")}</div>{/if}
    {#each message.notices as notice (notice)}<div class="notice">{notice}</div>{/each}
    {#if message.streaming && !text}
      <div class="status"><span class="dot working"></span> {message.status || "Denkt na…"}</div>
    {:else}
      <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
      <div class="markdown" onclick={click}>{@html html}</div>
    {/if}
    {#if message.references.length}
      <ol class="refs">
        {#each message.references as ref (ref.number)}
          <li>
            {#if ref.url}<a href={ref.url} onclick={(e) => { e.preventDefault(); openUrl(ref.url!); }}>{ref.title}</a>{:else}{ref.title}{/if}
            {#if ref.detail}<span class="faint"> — {ref.detail}</span>{/if}
          </li>
        {/each}
      </ol>
    {/if}
    {#if message.actions.length}
      <PlanCard {nookId} {message} />
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
  .error .markdown { color: var(--coral); }
  .status { color: var(--text2); display: flex; gap: 8px; align-items: center; }
  .looked { font-size: 11px; margin-bottom: 4px; }
  .notice { font-size: 12px; color: var(--amber); margin-bottom: 4px; }
  .refs { margin: 8px 0 0; padding-left: 20px; font-size: 12px; color: var(--text2); }
  .offers { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 8px; }
  .offers button { font-size: 12px; padding: 4px 10px; border-radius: 999px; }
</style>
