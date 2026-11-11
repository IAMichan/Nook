<script lang="ts">
  // Het hele gesprek uit het transcript van de agent, met zijn denkstappen ingeklapt ertussen.
  import { agentApi, type ChatMessage } from "../../lib/agents";
  import { renderMarkdown } from "../../lib/markdown";

  let { path, refreshKey = "" }: { path: string; refreshKey?: string } = $props();
  let messages = $state<ChatMessage[]>([]);
  let loading = $state(false);

  $effect(() => {
    void refreshKey;
    if (!path) {
      messages = [];
      return;
    }
    loading = true;
    agentApi.transcript(path).then((m) => {
      messages = m;
      loading = false;
    });
  });
</script>

<div class="conversation">
  {#each messages as m (m.id)}
    {#if m.kind === "thinking"}
      <details class="thinking"><summary>Denkstappen</summary><div class="markdown">{@html renderMarkdown(m.text)}</div></details>
    {:else}
      <div class="msg {m.kind}"><div class="markdown">{@html renderMarkdown(m.text)}</div></div>
    {/if}
  {:else}
    {#if loading}<p class="faint">Gesprek lezen…</p>{:else if path}<p class="faint">Nog niets in dit gesprek.</p>{/if}
  {/each}
</div>

<style>
  /* As a session Nook runs (EventRow): your message a round bubble on the right, the answer without one. */
  .conversation { display: flex; flex-direction: column; gap: 16px; }
  .msg { font-size: 14px; line-height: 1.6; }
  .msg.user { align-self: flex-end; max-width: 80%; padding: 8px 12px; border-radius: var(--radius-composer); background: var(--bubble); color: var(--paper); }
  .msg.assistant { align-self: stretch; padding: 2px 4px; color: var(--text-strong); }
  .thinking { color: var(--text2); font-size: 14px; padding: 0 4px; }
  .thinking summary { cursor: pointer; min-height: 24px; line-height: 24px; }
  .thinking .markdown { color: var(--text3); font-size: 13px; margin-left: 16px; }
</style>
