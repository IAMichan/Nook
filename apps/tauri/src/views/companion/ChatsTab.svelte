<script lang="ts">
  // The Chats tab of the iPhone app: every chat app the computer collects (WhatsApp through the linked phone, Telegram,
  // Messages, Slack…) in one list, newest first, with a search and All / Unread once there are more than eight.
  import { filterInbox, inboxStatus, shortTime, ticksMark, type InboxChatDigest } from "../../lib/companion";
  import { tr } from "../../lib/i18n.svelte";
  import Icon from "../../components/Icon.svelte";

  let { inbox, message, onopen }: { inbox: InboxChatDigest[]; message?: string; onopen: (id: string) => void } = $props();
  let query = $state("");
  let unreadOnly = $state(false);
  const chats = $derived(filterInbox(inbox, query, unreadOnly));
  const status = $derived(inboxStatus(message));
  const initials = (name: string) => name.split(/\s+/).filter(Boolean).slice(0, 2).map((w) => w[0]?.toUpperCase() ?? "").join("") || "?";
</script>

<div class="chats">
  {#if inbox.length > 8}
    <div class="bar">
      <label class="search">
        <Icon name="search" size={15} />
        <input bind:value={query} placeholder={tr("Zoek een chat", "Find a chat")} aria-label={tr("Zoek een chat", "Find a chat")} autocapitalize="off" />
      </label>
      <div class="filter" role="radiogroup" aria-label={tr("Toon", "Show")}>
        <button role="radio" aria-checked={!unreadOnly} class:on={!unreadOnly} onclick={() => (unreadOnly = false)}>{tr("Alles", "All")}</button>
        <button role="radio" aria-checked={unreadOnly} class:on={unreadOnly} onclick={() => (unreadOnly = true)}>{tr("Ongelezen", "Unread")}</button>
      </div>
    </div>
  {/if}
  <div class="list">
    {#if status}<p class="faint pad">{status}</p>{/if}
    {#each chats as c (c.id)}
      <button class="row" onclick={() => onopen(c.id)}>
        <span class="avatar">{initials(c.name)}</span>
        <span class="text">
          <span class="top"><strong>{c.name}</strong><span class="faint when">{shortTime(c.last)}</span></span>
          <span class="bottom">
            <span class="preview faint">
              {#if c.typing?.length}<em>{tr("typt…", "typing…")}</em>{:else}{#if c.ticks}<span class="ticks" class:read={c.ticks === "read"}>{ticksMark(c.ticks)}</span> {/if}{c.preview}{/if}
            </span>
            {#if c.unread > 0}<span class="count">{c.unread}</span>{/if}
          </span>
          <span class="app faint">{c.appName}</span>
        </span>
      </button>
    {:else}
      {#if !status}<p class="faint pad">{query.trim() || unreadOnly ? tr("Geen chat die daarop lijkt.", "No chat matches that.") : tr("Geen chats.", "No chats.")}</p>{/if}
    {/each}
  </div>
</div>

<style>
  .chats { flex: 1; min-height: 0; display: flex; flex-direction: column; }
  .bar { display: flex; flex-direction: column; gap: var(--space-8); padding: var(--space-8) var(--space-12); }
  .search { display: flex; align-items: center; gap: var(--space-6); padding: 0 var(--space-12); min-height: 40px; border-radius: var(--radius-control); background: var(--field); border: 1px solid var(--field-stroke); color: var(--text3); }
  .search input { flex: 1; min-width: 0; border: none; background: transparent; padding: 0; min-height: 38px; }
  .filter { display: flex; gap: var(--space-4); }
  .filter button { min-height: 32px; padding: 0 var(--space-12); border-radius: var(--radius-pill); background: transparent; color: var(--text2); font: var(--text-label); }
  .filter button.on { background: var(--smoke); color: var(--paper); }
  .list { flex: 1; overflow-y: auto; padding: var(--space-4) 0 var(--space-24); }
  .row { width: 100%; display: flex; gap: var(--space-12); align-items: center; text-align: left; background: none; border: none; padding: var(--space-8) var(--space-16); min-height: 64px; }
  .row:active { background: var(--row-hover); }
  .avatar { width: 40px; height: 40px; border-radius: 50%; background: var(--smoke); display: flex; align-items: center; justify-content: center; font: var(--text-label); color: var(--text2); flex: none; }
  .text { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: var(--space-2); }
  .top, .bottom { display: flex; align-items: center; gap: var(--space-8); min-width: 0; }
  .top strong { flex: 1; min-width: 0; font: var(--text-control); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .when { flex: none; font: var(--text-caption); }
  .preview { flex: 1; min-width: 0; font: var(--text-detail); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .ticks.read { color: var(--blue); }
  .app { font: var(--text-caption); }
  .count { min-width: 20px; height: 20px; padding: 0 var(--space-6); border-radius: var(--radius-pill); background: var(--mint); color: var(--ink); font: var(--text-caption); display: inline-flex; align-items: center; justify-content: center; flex: none; }
  .pad { padding: var(--space-16); margin: 0; }
</style>
