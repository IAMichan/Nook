<script lang="ts">
  // A shared session strip above the composer (`GuestStrip.swift` on the Mac, AG-81): shows that a guest link is live,
  // until when, how many viewers follow, and any messages a guest wrote. Held guest messages never reach the agent
  // until you explicitly click Send; Dismiss removes the message and deletes any attached files.
  import Ico from "../../../components/ui/Ico.svelte";
  import { locale, tr } from "../../../lib/i18n.svelte";
  import { toast } from "../../../lib/toast.svelte";
  import { formatGuestUntil, guestFileNames, guestStatusKey } from "../../../lib/workspace/guest-shares";
  import { guestShares } from "../../../lib/workspace/guest-shares.svelte";

  let { runId }: { runId: string } = $props();

  let copied = $state(false);
  let busyId = $state<string | null>(null);
  let stopping = $state(false);
  let copyTimer: ReturnType<typeof setTimeout> | null = null;

  const share = $derived(guestShares.forRun(runId));

  const statusText = $derived.by(() => {
    if (!share) return "";
    const time = formatGuestUntil(share.until, locale());
    const bucket = guestStatusKey(share.watching);
    if (bucket === "one") {
      return tr("Een gast volgt deze sessie · link werkt tot {time}", "A guest follows this session · link works until {time}", { time });
    }
    if (bucket === "many") {
      return tr(
        "Gasten volgen deze sessie · link werkt tot {time} · {count} kijken mee",
        "Guests follow this session · link works until {time} · {count} watching",
        { time, count: share.watching },
      );
    }
    return tr("Gedeeld via een gastlink tot {time}", "Shared through a guest link until {time}", { time });
  });

  async function copyLink() {
    if (!share?.link) return;
    try {
      await navigator.clipboard.writeText(share.link);
      copied = true;
      if (copyTimer) clearTimeout(copyTimer);
      copyTimer = setTimeout(() => {
        copied = false;
      }, 1500);
    } catch (e) {
      toast.error(tr("Kon de sessie niet kopiëren", "Could not copy the session"), e);
    }
  }

  async function stopSharing() {
    if (stopping) return;
    stopping = true;
    try {
      await guestShares.stop(runId);
    } finally {
      stopping = false;
    }
  }

  async function sendHeld(messageId: string) {
    if (busyId) return;
    busyId = messageId;
    try {
      await guestShares.sendHeld(runId, messageId);
    } catch (e) {
      toast.error(tr("Kon het gastbericht niet sturen", "Could not send the guest message"), e);
    } finally {
      busyId = null;
    }
  }

  async function dismissHeld(messageId: string) {
    if (busyId) return;
    busyId = messageId;
    try {
      await guestShares.dismissHeld(runId, messageId);
    } finally {
      busyId = null;
    }
  }
</script>

{#if share}
  <div class="guest-strip" role="region" aria-label={tr("Gastlink", "Guest link")}>
    <div class="row">
      <div class="info">
        <span class="ico"><Ico name="shield-check" size={13} stroke={2.1} /></span>
        <span class="status">{statusText}</span>
      </div>
      <div class="actions">
        <button type="button" class="ghost small" onclick={copyLink}>
          {#if copied}<Ico name="check" size={11} stroke={2.5} />{/if}
          <span>{tr("Kopieer link", "Copy link")}</span>
        </button>
        <button type="button" class="ghost small" disabled={stopping} onclick={stopSharing}>
          {tr("Stop met delen", "Stop sharing")}
        </button>
      </div>
    </div>

    {#each share.held as message (message.id)}
      <div class="row held">
        <div class="held-body">
          <span class="held-from">{tr("Een gast schreef", "A guest wrote")}</span>
          {#if message.text}
            <p class="held-text">{message.text}</p>
          {/if}
          {#if message.files.length}
            <span class="held-files">{guestFileNames(message.files)}</span>
          {/if}
        </div>
        <div class="actions">
          <button
            type="button"
            class="primary small"
            disabled={busyId === message.id}
            onclick={() => sendHeld(message.id)}
          >
            {tr("Stuur", "Send")}
          </button>
          <button
            type="button"
            class="ghost small"
            disabled={busyId === message.id}
            onclick={() => dismissHeld(message.id)}
          >
            {tr("Negeer", "Dismiss")}
          </button>
        </div>
      </div>
    {/each}
  </div>
{/if}

<style>
  .guest-strip {
    display: flex;
    flex-direction: column;
    gap: var(--space-8);
    padding: var(--space-8) var(--space-12);
    border: 1px solid var(--line2);
    border-radius: var(--radius-card);
    background: var(--surface);
    font: var(--text-detail);
    color: var(--text2);
    min-width: 0;
  }
  .row {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-8);
    min-width: 0;
  }
  .held {
    padding-top: var(--space-8);
    border-top: 1px solid var(--line);
    align-items: flex-start;
  }
  .info {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    flex: 1 1 200px;
    min-width: 0;
  }
  .ico {
    display: inline-flex;
    flex: none;
    color: var(--text2);
  }
  .status {
    color: var(--text2);
    min-width: 0;
  }
  .held-body {
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    flex: 1 1 200px;
    min-width: 0;
  }
  .held-from {
    color: var(--amber);
    font: var(--text-label);
  }
  .held-text {
    margin: 0;
    color: var(--paper);
    white-space: pre-wrap;
    word-break: break-word;
    display: -webkit-box;
    -webkit-line-clamp: 6;
    line-clamp: 6;
    -webkit-box-orient: vertical;
    overflow: hidden;
  }
  .held-files {
    color: var(--text3);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .actions {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: var(--space-6);
    flex: none;
  }
  .small {
    display: inline-flex;
    align-items: center;
    gap: var(--space-4);
    padding: var(--space-4) var(--space-8);
    font: var(--text-label);
  }
</style>
