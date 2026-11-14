<script lang="ts">
  // One session in the list. What waits on you first is one tap away: deny always, allow when it is low risk.
  import { attentionColor, attentionWord, companion, shortTime, type ClientView, type SessionDigest } from "../../lib/companion";
  import { tr } from "../../lib/i18n.svelte";

  let { session, onopen, act, canApprove = true }: {
    session: SessionDigest;
    onopen: () => void;
    act: (f: () => Promise<ClientView>) => Promise<void>;
    canApprove?: boolean;
  } = $props();
  const approval = $derived(canApprove ? session.items.find((i) => i.kind === "approval") : undefined);
</script>

<div class="row">
  <button class="open" onclick={onopen}>
    <span class="line">
      <span class="dot" style="background:{attentionColor(session.attention)}"></span>
      <span class="folder faint">{session.folder} /</span>
      <strong>{session.title}</strong>
      <span class="when faint">{shortTime(session.updated)}</span>
    </span>
    <span class="faint meta">{attentionWord(session.attention)} · {session.agent}{session.branch ? ` · ${session.branch}` : ""}</span>
    {#if session.items.length}<span class="first">{session.items[0].title}</span>{/if}
  </button>
  {#if approval}
    <div class="quick">
      <button class="danger" onclick={() => act(() => companion.decide(session.id, approval.id, false))}>{tr("Weiger", "Deny")}</button>
      {#if approval.canAllow}
        <button class="allow" onclick={() => act(() => companion.decide(session.id, approval.id, true))}>{tr("Sta toe", "Allow")}</button>
      {/if}
    </div>
  {/if}
</div>

<style>
  .row { padding: var(--space-2) var(--space-8); }
  .open { width: 100%; display: flex; flex-direction: column; align-items: stretch; gap: var(--space-4); text-align: left; background: none; border: none; padding: var(--space-8); min-height: 56px; border-radius: var(--radius-card); }
  .open:hover, .open:active { background: var(--row-hover); }
  .line { display: flex; align-items: center; gap: var(--space-6); min-width: 0; }
  .folder { flex: none; max-width: 40%; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; font: var(--text-detail); }
  .line strong { flex: 1; min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; font: var(--text-title); }
  .when { flex: none; font: var(--text-caption); }
  .meta { font: var(--text-detail); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .first { color: var(--amber); font: var(--text-detail); display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
  .dot { width: 8px; height: 8px; border-radius: 50%; flex: none; }
  .quick { display: flex; gap: var(--space-8); padding: 0 var(--space-8) var(--space-8); }
  .quick button { flex: 1; min-height: 44px; }
  .allow { color: var(--mint); }
</style>
