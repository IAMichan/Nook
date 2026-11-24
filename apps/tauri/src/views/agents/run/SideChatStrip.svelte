<script lang="ts">
  // Quick side chat cards (`/btw`, `/side`, AG-61) above a session's composer: lets you ask a quick question
  // about the session while the main agent keeps running uninterrupted, with Copy and Dismiss.
  import Ico from "../../../components/ui/Ico.svelte";
  import { tr } from "../../../lib/i18n.svelte";
  import { toast } from "../../../lib/toast.svelte";

  export interface SideChatItem {
    id: string;
    question: string;
    answer: string | null;
    error: string | null;
    model: string | null;
    loading: boolean;
  }

  let {
    items,
    ondismiss,
  }: {
    items: SideChatItem[];
    ondismiss: (id: string) => void;
  } = $props();

  let copiedId = $state<string | null>(null);

  async function copyAnswer(item: SideChatItem) {
    if (!item.answer) return;
    try {
      await navigator.clipboard.writeText(item.answer);
      copiedId = item.id;
      toast.success(tr("Antwoord gekopieerd", "Answer copied"));
      setTimeout(() => {
        if (copiedId === item.id) copiedId = null;
      }, 1500);
    } catch (e) {
      toast.error(tr("Kon het antwoord niet kopiëren", "Could not copy the answer"), e);
    }
  }
</script>

{#if items.length}
  <div class="side-strip" role="region" aria-label={tr("Zijgesprek", "Side chat")}>
    {#each items as item (item.id)}
      <article class="side-card">
        <header class="side-head">
          <span class="side-ico" class:spin={item.loading}>
            <Ico name={item.loading ? "loader-circle" : "messages-square"} size={13} stroke={2} />
          </span>
          <span class="side-tag">{tr("Zijgesprek", "Side chat")}</span>
          <span class="side-question" title={item.question}>{item.question}</span>
          {#if item.answer}
            <button
              type="button"
              class="side-act"
              title={tr("Kopieer antwoord", "Copy answer")}
              aria-label={tr("Kopieer antwoord", "Copy answer")}
              onclick={() => copyAnswer(item)}
            >
              <Ico name={copiedId === item.id ? "check" : "copy"} size={12} stroke={2.2} />
            </button>
          {/if}
          <button
            type="button"
            class="side-act"
            title={tr("Sluit zijgesprek", "Dismiss side chat")}
            aria-label={tr("Sluit zijgesprek", "Dismiss side chat")}
            onclick={() => ondismiss(item.id)}
          >
            <Ico name="x" size={12} stroke={2.4} />
          </button>
        </header>
        {#if item.loading}
          <p class="side-status">{tr("Bezig met antwoorden…", "Answering…")}</p>
        {:else if item.error}
          <p class="side-error">{item.error}</p>
        {:else if item.answer}
          <div class="side-answer">{item.answer}</div>
        {/if}
      </article>
    {/each}
  </div>
{/if}

<style>
  .side-strip {
    display: flex;
    flex-direction: column;
    gap: var(--space-6);
  }
  .side-card {
    display: flex;
    flex-direction: column;
    gap: var(--space-6);
    padding: var(--space-8) var(--space-12);
    border: 1px solid var(--line2);
    border-radius: var(--radius-card);
    background: var(--surface);
    color: var(--text2);
    min-width: 0;
  }
  .side-head {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    min-width: 0;
  }
  .side-ico {
    display: inline-flex;
    flex: none;
    color: var(--text2);
  }
  .side-ico.spin {
    animation: side-spin 1s linear infinite;
  }
  @keyframes side-spin {
    from { transform: rotate(0deg); }
    to { transform: rotate(360deg); }
  }
  .side-tag {
    flex: none;
    font: var(--text-detail);
    color: var(--text3);
  }
  .side-question {
    flex: 1;
    min-width: 0;
    font: var(--text-detail);
    color: var(--paper);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .side-act {
    display: grid;
    place-items: center;
    width: 22px;
    height: 22px;
    flex: none;
    padding: 0;
    margin: 0;
    border: 0;
    border-radius: var(--radius-chip);
    background: transparent;
    color: var(--text3);
    cursor: pointer;
  }
  .side-act:hover {
    background: var(--smoke);
    color: var(--paper);
  }
  .side-status {
    margin: 0;
    font: var(--text-detail);
    color: var(--text3);
  }
  .side-error {
    margin: 0;
    font: var(--text-detail);
    color: var(--coral);
    white-space: pre-wrap;
  }
  .side-answer {
    font: var(--text-body);
    color: var(--paper);
    white-space: pre-wrap;
    overflow-wrap: anywhere;
    max-height: 220px;
    overflow-y: auto;
  }
</style>
