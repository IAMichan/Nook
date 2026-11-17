<script lang="ts">
  // Het hele gesprek uit het transcript van de agent, met zijn denkstappen ingeklapt ertussen.
  import { agentApi, type ChatMessage } from "../../lib/agents";
  import { agents } from "../../lib/agents.svelte";
  import Markdown from "../../components/Markdown.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import { toast } from "../../lib/toast.svelte";
  import { toolsApi } from "../../lib/workspace/api";

  let {
    path,
    refreshKey = "",
    baseFolder = null,
  }: { path: string; refreshKey?: string; baseFolder?: string | null } = $props();
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

  async function runCode(command: string, title: string | null) {
    if (!baseFolder) return;
    try {
      await toolsApi.openTerminal(baseFolder, command, title);
      agents.select("terminals");
    } catch (e) {
      toast.error(tr("Kon terminal niet openen", "Could not open terminal"), e);
    }
  }
</script>

<div class="conversation">
  {#each messages as m (m.id)}
    {#if m.kind === "thinking"}
      <details class="thinking"><summary>{tr("Denkstappen", "Thinking")}</summary><div class="thinking-body"><Markdown text={m.text} {baseFolder} onrun={baseFolder ? runCode : undefined} /></div></details>
    {:else}
      <div class="msg {m.kind}"><Markdown text={m.text} {baseFolder} onrun={baseFolder ? runCode : undefined} /></div>
    {/if}
  {:else}
    {#if loading}<p class="faint">{tr("Gesprek lezen…", "Reading conversation…")}</p>{:else if path}<p class="faint">{tr("Nog niets in dit gesprek.", "Nothing in this conversation yet.")}</p>{/if}
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
  .thinking-body { color: var(--text3); font-size: 13px; margin-left: 16px; }
</style>
