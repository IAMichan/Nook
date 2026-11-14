<script lang="ts">
  // A session's conversation as the iPhone app reads it: your messages, the agent's replies as Markdown, the tools it
  // ran and the files it changed (open one for its output), errors and quiet notices.
  import type { TimelineEntry } from "../../lib/companion";
  import { renderMarkdown } from "../../lib/markdown";
  import { tr } from "../../lib/i18n.svelte";

  let { entries }: { entries: TimelineEntry[] } = $props();
</script>

{#each entries as e (e.id)}
  {#if e.kind === "user"}
    <div class="mine">{e.text}</div>
  {:else if e.kind === "assistant"}
    <div class="markdown reply">{@html renderMarkdown(e.text)}</div>
    {#if e.clipped}<p class="faint small">{tr("Ingekort: lees het hele bericht op je computer.", "Shortened: read the whole message on your computer.")}</p>{/if}
  {:else if e.kind === "tool" || e.kind === "change"}
    {#if e.output}
      <details class="step" class:failed={e.failed}>
        <summary><span class="mark">{e.kind === "change" ? "✎" : "›"}</span> <span class="what">{e.detail ? `${e.detail} · ` : ""}{e.text}</span></summary>
        <pre>{e.output}</pre>
      </details>
    {:else}
      <div class="step plain" class:failed={e.failed}><span class="mark">{e.kind === "change" ? "✎" : "›"}</span> <span class="what">{e.detail ? `${e.detail} · ` : ""}{e.text}</span></div>
    {/if}
  {:else if e.kind === "error"}
    <div class="error">{e.text}</div>
  {:else}
    <div class="notice faint">{e.detail === "compacted" ? tr("Context samengevat", "Context compacted") : e.text}</div>
  {/if}
{/each}

<style>
  .mine { align-self: flex-end; max-width: 85%; background: var(--bubble); border-radius: var(--radius-bubble); padding: var(--space-8) var(--space-12); white-space: pre-wrap; font: var(--text-body); user-select: text; overflow-wrap: anywhere; }
  .reply { font: var(--text-body); overflow-wrap: anywhere; }
  .step { font: var(--text-detail); color: var(--text2); border-left: 2px solid var(--line2); padding-left: var(--space-8); }
  .step summary { cursor: pointer; list-style: none; display: flex; gap: var(--space-4); min-height: 28px; align-items: center; }
  .step summary::-webkit-details-marker { display: none; }
  .step.plain { display: flex; gap: var(--space-4); min-height: 24px; align-items: center; }
  .what { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; min-width: 0; }
  .step.failed { border-left-color: var(--coral); }
  .mark { color: var(--text3); flex: none; }
  pre { margin: var(--space-6) 0 0; max-height: 280px; overflow: auto; background: var(--field); border: 1px solid var(--line2); border-radius: var(--radius-card); padding: var(--space-8); font: var(--text-code); white-space: pre; user-select: text; }
  .error { color: var(--coral); font: var(--text-detail); white-space: pre-wrap; }
  .notice { align-self: center; font: var(--text-caption); text-align: center; }
  .small { font: var(--text-detail); margin: 0; }
</style>
