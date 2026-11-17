<script lang="ts">
  // Questions waiting for the answer Nook is writing, in the tray above the composer (the Mac's `QueuedMessagesStrip`):
  // a header that folds the list, then each question with its place in line. Under the pointer a row shows Send now,
  // Remove and, with more than one, Move up and Move down.
  import Ico from "./ui/Ico.svelte";
  import { tr } from "../lib/i18n.svelte";
  import type { MessageQueue } from "../lib/types";

  let { queue, remove, move, sendNow }: {
    queue: MessageQueue;
    remove: (id: string) => void;
    move: (id: string, to: number) => void;
    sendNow: (id: string) => void;
  } = $props();

  let collapsed = $state(false);
  const count = $derived(queue.messages.length);
  const note = $derived(queue.isHeld ? tr("Gepauzeerd na een fout of stop", "Paused after an error or stop") : tr("Gaat vanzelf na deze beurt", "Goes out after this turn"));
  const title = $derived(tr("In de wachtrij ({n})", "Queued ({n})", { n: count }));
</script>

<div class="tray">
  <button class="head" onclick={() => (collapsed = !collapsed)} aria-expanded={!collapsed} aria-label={title} title={note}>
    <span class="chev" class:open={!collapsed}><Ico name="chevron-right" size={10} stroke={2.4} /></span>
    <span class="title">{title}</span>
    <span class="grow"></span>
    <span class="note" class:held={queue.isHeld}>{note}</span>
  </button>
  {#if !collapsed}
    {#each queue.messages as m, i (m.id)}
      <div class="row">
        <span class="place" aria-hidden="true">{i + 1}</span>
        {#if m.imageCount}<span class="pictures" title={tr("{n} afbeeldingen", "{n} images", { n: m.imageCount })}><Ico name="image" size={12} /></span>{/if}
        {#if m.documentName}<span class="pictures" title={m.documentName}><Ico name="file-text" size={12} /></span>{/if}
        <span class="text">{m.text.replace(/\s+/g, " ") || m.documentName}</span>
        <span class="actions">
          <button class="icon" title={tr("Nu versturen", "Send now")} aria-label={tr("Nu versturen", "Send now")} onclick={() => sendNow(m.id)}><Ico name="send" size={13} /></button>
          <button class="icon" title={tr("Uit de wachtrij halen", "Remove from queue")} aria-label={tr("Uit de wachtrij halen", "Remove from queue")} onclick={() => remove(m.id)}><Ico name="x" size={13} /></button>
          {#if count > 1}
            <span class="divider"></span>
            <button class="icon" title={tr("Omhoog", "Move up")} aria-label={tr("Omhoog", "Move up")} disabled={i === 0} onclick={() => move(m.id, i - 1)}><Ico name="arrow-up" size={13} /></button>
            <button class="icon" title={tr("Omlaag", "Move down")} aria-label={tr("Omlaag", "Move down")} disabled={i === count - 1} onclick={() => move(m.id, i + 1)}><Ico name="arrow-down" size={13} /></button>
          {/if}
        </span>
      </div>
    {/each}
  {/if}
</div>

<style>
  .tray {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    padding: var(--space-4);
    border: 1px solid var(--line2);
    border-bottom: 0;
    border-radius: var(--radius-card) var(--radius-card) 0 0;
    background: var(--surface);
  }
  .head {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    padding: var(--space-2) var(--space-8);
    border: 0;
    background: none;
    color: var(--text2);
    cursor: pointer;
    text-align: left;
  }
  .chev { display: inline-flex; transition: transform 0.15s; }
  .chev.open { transform: rotate(90deg); }
  .title { font: var(--text-label); }
  .grow { flex: 1; }
  .note { font: var(--text-detail); color: var(--text3); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .note.held { color: var(--amber); }
  .row {
    position: relative;
    display: flex;
    align-items: center;
    gap: var(--space-12);
    padding: var(--space-4) var(--space-8);
    border-radius: var(--radius-control);
  }
  .row:hover { background: var(--row-hover); }
  .place {
    flex: none;
    display: grid;
    place-items: center;
    width: 18px;
    height: 18px;
    border-radius: 999px;
    background: var(--smoke);
    color: var(--text2);
    font: var(--text-caption);
    font-variant-numeric: tabular-nums;
  }
  .pictures { flex: none; display: inline-flex; color: var(--text3); }
  .text { flex: 1; min-width: 0; font: var(--text-body); color: var(--text-strong); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .actions {
    position: absolute;
    right: var(--space-8);
    display: flex;
    align-items: center;
    gap: var(--space-2);
    padding-left: var(--space-16);
    background: linear-gradient(to right, transparent, var(--row-hover) var(--space-16));
    opacity: 0;
    pointer-events: none;
    transition: opacity 0.12s;
  }
  .row:hover .actions, .row:focus-within .actions { opacity: 1; pointer-events: auto; }
  .divider { width: 1px; height: 12px; margin: 0 var(--space-2); background: var(--line2); }
  .icon {
    display: grid;
    place-items: center;
    width: 22px;
    height: 22px;
    padding: 0;
    border: 0;
    border-radius: var(--radius-control);
    background: none;
    color: var(--text2);
    cursor: pointer;
  }
  .icon:hover:not(:disabled) { background: var(--smoke); color: var(--paper); }
  .icon:disabled { opacity: 0.35; cursor: default; }
  @media (prefers-reduced-motion: reduce) { .chev, .actions { transition: none; } }
</style>
