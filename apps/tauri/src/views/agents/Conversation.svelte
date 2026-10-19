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
      <details class="thinking"><summary>Denkt na</summary><div class="markdown">{@html renderMarkdown(m.text)}</div></details>
    {:else}
      <div class="msg {m.kind}"><div class="markdown">{@html renderMarkdown(m.text)}</div></div>
    {/if}
  {:else}
    {#if loading}<p class="faint">Gesprek lezen…</p>{:else if path}<p class="faint">Nog niets in dit gesprek.</p>{/if}
  {/each}
</div>

<style>
  .conversation { display: flex; flex-direction: column; gap: 8px; }
  .msg { padding: 8px 12px; border-radius: 12px; max-width: 92%; }
  .msg.user { align-self: flex-end; background: var(--smoke); }
  .msg.assistant { align-self: flex-start; background: transparent; padding-left: 0; }
  .thinking { color: var(--text3); font-size: 12px; }
  .thinking summary { cursor: pointer; }
</style>
