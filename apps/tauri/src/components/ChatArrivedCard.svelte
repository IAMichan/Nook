<script lang="ts">
  // The card of a chat that just wrote (any app but WhatsApp, which has its own): context with app icon, contact heading,
  // recent messages as tailed bubbles with timestamps, an integrated reply box, and Read / Later + Open in Nook
  // (the Mac's notch chat card: `CardView`, `ChatTranscript`, `ChatReplyField`, `NookSplitButton`).
  import { tr } from "../lib/i18n.svelte";
  import { arrivedChat } from "../lib/chat-arrived.svelte";
  import { appName, chatApps, personTint } from "../lib/chats-list";
  import { time } from "../lib/whatsapp";
  import ServiceIcon from "../views/connectors/ServiceIcon.svelte";
  import Ico from "./ui/Ico.svelte";

  let { onopen }: { onopen: (key: string) => void } = $props();
  const thread = $derived(arrivedChat.thread);
  const recent = $derived((thread?.messages ?? []).filter((m) => !m.deleted).slice(-4));
  const runs = $derived.by(() => {
    const list = recent;
    const who = (m: (typeof list)[number]) => (m.fromMe ? "\u0000me" : m.sender || "");
    return list.map((m, i) => ({
      m,
      first: !list[i - 1] || who(list[i - 1]) !== who(m),
      last: !list[i + 1] || who(list[i + 1]) !== who(m),
    }));
  });
  const unreadCount = $derived(
    thread?.read.state === "unread" ? thread.read.count : (arrivedChat.pending?.unread ?? 0)
  );
  const canSend = $derived(!!arrivedChat.draft.trim() && !arrivedChat.sending);
</script>

{#if thread}
  <div class="arrived" role="region" aria-label={thread.name}>
    <div class="head">
      <div class="context">
        <ServiceIcon domain={chatApps[thread.app]?.domain} title={appName(thread.app)} size={16} />
        <span class="ctx-text">
          {appName(thread.app)}{#if unreadCount > 0} · {tr("{n} ongelezen", "{n} unread", { n: unreadCount })}{/if}
        </span>
      </div>
      <h3 class="title">{thread.name}</h3>
    </div>

    <div class="bubbles">
      {#each runs as { m, first, last } (m.id)}
        <div class="line" class:mine={m.fromMe} class:first>
          <div class="bubble" class:mine={m.fromMe} class:tailed={first} class:joins={!last}>
            {#if first && !m.fromMe && m.sender && m.sender !== thread.name}
              <span class="sender" style:color={personTint(m.sender)}>{m.sender}</span>
            {/if}
            <span class="msg-body">
              <span class="text">{m.text || "📎"}</span>
              {#if last && m.date}<span class="stamp">{time(m.date)}</span>{/if}
            </span>
          </div>
        </div>
      {/each}
    </div>

    {#if arrivedChat.error}<span class="error">{arrivedChat.error}</span>{/if}

    {#if thread.sends}
      <form class="reply-box" onsubmit={(e) => { e.preventDefault(); arrivedChat.send(); }}>
        <input
          bind:value={arrivedChat.draft}
          placeholder={tr("Antwoord aan {name}", "Reply to {name}", { name: thread.name })}
          aria-label={tr("Antwoord aan {name}", "Reply to {name}", { name: thread.name })}
          disabled={arrivedChat.sending}
        />
        <button class="send" class:ready={canSend} type="submit" disabled={!canSend} aria-label={tr("Versturen", "Send")}>
          <Ico name="arrow-up" size={14} stroke={2.5} />
        </button>
      </form>
    {/if}

    <div class="actions-row">
      <div class="split-pill">
        <button class="split-primary" onclick={() => arrivedChat.markRead()}>
          <Ico name="check" size={13} stroke={2.5} />
          <span>{tr("Gelezen", "Read")}</span>
        </button>
        <button class="split-secondary" onclick={() => arrivedChat.dismiss()}>
          {tr("Later", "Later")}
        </button>
      </div>
      <button class="extra" onclick={() => onopen(thread.key)}>
        <Ico name="messages-square" size={13} />
        <span>{tr("Open in Nook", "Open in Nook")}</span>
      </button>
    </div>
  </div>
{/if}

<style>
  .arrived {
    margin: var(--space-8) var(--space-16) var(--space-4);
    padding: var(--space-12) var(--space-16);
    background: var(--surface);
    border: 1px solid var(--line);
    border-radius: var(--radius-panel);
    display: flex;
    flex-direction: column;
    gap: var(--space-8);
  }
  .head { display: flex; flex-direction: column; gap: var(--space-4); }
  .context { display: flex; align-items: center; gap: var(--space-6); min-width: 0; }
  .ctx-text { font: var(--text-label); color: var(--text2); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .title { margin: 0; font: var(--text-heading); color: var(--paper); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }

  .bubbles { display: flex; flex-direction: column; max-height: 184px; overflow-y: auto; padding: var(--space-2) 0; }
  .line { display: flex; padding-top: var(--space-2); padding-right: 48px; }
  .line.first { padding-top: var(--space-6); }
  .line:first-child { padding-top: 0; }
  .line.mine { justify-content: flex-end; padding-right: 0; padding-left: 48px; }
  .bubble {
    position: relative;
    max-width: 100%;
    min-width: 0;
    display: flex;
    flex-direction: column;
    gap: var(--space-2);
    padding: var(--space-6) 10px;
    margin-left: 7px;
    background: var(--chat-theirs);
    border-radius: var(--radius-chat-bubble);
    color: var(--paper);
    user-select: text;
  }
  .bubble.mine { margin-left: 0; margin-right: 7px; background: var(--chat-mine); }
  .bubble:not(.tailed) { border-top-left-radius: var(--radius-chat-join); }
  .bubble.mine:not(.tailed) { border-top-left-radius: var(--radius-chat-bubble); border-top-right-radius: var(--radius-chat-join); }
  .bubble.joins { border-bottom-left-radius: var(--radius-chat-join); }
  .bubble.mine.joins { border-bottom-left-radius: var(--radius-chat-bubble); border-bottom-right-radius: var(--radius-chat-join); }
  .bubble.tailed { border-top-left-radius: 0; }
  .bubble.mine.tailed { border-top-left-radius: var(--radius-chat-bubble); border-top-right-radius: 0; }
  .bubble.tailed::before {
    content: "";
    position: absolute;
    top: 0;
    left: -7px;
    width: 7px;
    height: 9px;
    background: inherit;
    clip-path: polygon(0 0, 100% 0, 100% 100%);
  }
  .bubble.mine.tailed::before { left: auto; right: -7px; clip-path: polygon(0 0, 100% 0, 0 100%); }
  .sender { font: var(--text-label); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .msg-body { display: flex; flex-wrap: wrap; align-items: flex-end; justify-content: flex-end; column-gap: var(--space-8); }
  .text { flex: 1 1 auto; min-width: 0; font: var(--text-body); color: var(--paper); white-space: pre-wrap; overflow-wrap: anywhere; }
  .stamp { margin-left: auto; font: var(--text-caption); font-variant-numeric: tabular-nums; color: var(--chat-stamp); white-space: nowrap; }

  .error { font: var(--text-detail); color: var(--coral); }

  /* Integrated reply box (`ChatReplyField`): composer tray with the round send button inside its right edge. */
  .reply-box {
    display: flex;
    align-items: center;
    gap: var(--space-8);
    padding: var(--space-4) var(--space-4) var(--space-4) var(--space-12);
    background: var(--composer-tray);
    border: 1px solid var(--field-stroke);
    border-radius: var(--radius-composer);
    transition: background var(--motion-quick), border-color var(--motion-quick);
  }
  .reply-box:focus-within { background: var(--composer); border-color: var(--separator); }
  .reply-box input {
    flex: 1;
    min-width: 0;
    padding: var(--space-4) 0;
    border: 0;
    background: transparent;
    box-shadow: none;
    outline: none;
    font: var(--text-body);
    color: var(--paper);
  }
  .reply-box input::placeholder { color: var(--text3); }
  .send {
    flex: none;
    display: grid;
    place-items: center;
    width: 28px;
    height: 28px;
    padding: 0;
    border: 0;
    border-radius: 999px;
    background: var(--smoke);
    color: var(--text3);
    cursor: default;
    transition: background var(--motion-quick), color var(--motion-quick);
  }
  .send.ready { background: var(--iris); color: var(--on-iris); cursor: pointer; }
  .send.ready:hover:not(:disabled) { background: color-mix(in srgb, var(--iris) 88%, var(--canvas)); }

  /* Bottom action row (`NookNoticeActions` + `NookSplitButton`): primary + secondary in one pill, extra ghost beside it. */
  .actions-row { display: flex; align-items: center; gap: var(--space-4); flex-wrap: wrap; }
  .split-pill {
    display: inline-flex;
    align-items: center;
    height: 36px;
    padding: 3px;
    box-sizing: border-box;
    background: var(--smoke);
    border-radius: var(--radius-control);
  }
  .split-primary {
    display: inline-flex;
    align-items: center;
    gap: var(--space-6);
    height: 100%;
    padding: 0 var(--space-16);
    border: 0;
    border-radius: var(--radius-chip);
    background: var(--iris);
    color: var(--on-iris);
    font: var(--text-emphasis);
    font-weight: 600;
    cursor: pointer;
    transition: background var(--motion-quick);
  }
  .split-primary:hover { background: color-mix(in srgb, var(--iris) 88%, var(--canvas)); }
  .split-secondary {
    display: inline-flex;
    align-items: center;
    height: 100%;
    padding: 0 var(--space-16);
    border: 0;
    border-radius: var(--radius-chip);
    background: transparent;
    color: var(--text2);
    font: var(--text-emphasis);
    font-weight: 600;
    cursor: pointer;
    transition: color var(--motion-quick);
  }
  .split-secondary:hover { color: var(--paper); }
  .extra {
    display: inline-flex;
    align-items: center;
    gap: var(--space-6);
    height: 36px;
    padding: 0 var(--space-12);
    border: 0;
    border-radius: var(--radius-control);
    background: transparent;
    color: var(--text2);
    font: var(--text-control);
    cursor: pointer;
    transition: background var(--motion-quick), color var(--motion-quick);
  }
  .extra:hover { background: var(--smoke); color: var(--paper); }
</style>
