<script lang="ts">
  // Eén sessie in de lijst. Wat het eerst op je wacht ligt één tik weg: weigeren altijd, toestaan als het laag risico is.
  import { attentionColor, attentionWord, companion, type ClientView, type SessionDigest } from "../../lib/companion";

  let { session, onopen, act }: { session: SessionDigest; onopen: () => void; act: (f: () => Promise<ClientView>) => Promise<void> } = $props();
  const approval = $derived(session.items.find((i) => i.kind === "approval"));
</script>

<div class="row">
  <button class="open" onclick={onopen}>
    <span class="line">
      <span class="dot" style="background:{attentionColor(session.attention)}"></span>
      <strong>{session.title}</strong>
    </span>
    <span class="faint meta">{attentionWord(session.attention)} · {session.agent} · {session.folder}</span>
    {#if session.items.length}<span class="first">{session.items[0].title}</span>{/if}
  </button>
  {#if approval}
    <div class="quick">
      <button class="danger" onclick={() => act(() => companion.decide(session.id, approval.id, false))}>Weiger</button>
      {#if approval.canAllow}
        <button class="allow" onclick={() => act(() => companion.decide(session.id, approval.id, true))}>Sta toe</button>
      {/if}
    </div>
  {/if}
</div>

<style>
  .row { border-bottom: 1px solid var(--line); padding: 4px 8px; }
  .open { width: 100%; display: flex; flex-direction: column; align-items: stretch; gap: 4px; text-align: left; background: none; border: none; padding: 10px 8px; min-height: 56px; border-radius: 10px; }
  .open:hover, .open:active { background: var(--smoke); }
  .line { display: flex; align-items: center; gap: 8px; }
  .line strong { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; font-size: 14px; }
  .meta { font-size: 12px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .first { color: var(--amber); font-size: 13px; display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
  .dot { width: 9px; height: 9px; }
  .quick { display: flex; gap: 8px; padding: 0 8px 8px; }
  .quick button { flex: 1; min-height: 44px; }
  .allow { color: var(--mint); }
</style>
