<script lang="ts">
  // Who a chat is with (`ChatsInfoSheet`), from its face or name in the header: the picture, the name, the app and
  // account, a group's members, and what can be done with the chat (the same steps as its "…" menu). For every app.
  import { appName, type ChatEntry } from "../../lib/chats-list";
  import { canCallChat, type CallKind } from "../../lib/chats-call";
  import { activeCall } from "../../lib/chats-call.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import CallIcon from "./CallIcon.svelte";
  import ChatFace from "./ChatFace.svelte";
  import { chatMenu } from "./chat-actions.svelte";

  let { entry, people, anchor, onclose, onclosechat }: {
    entry: ChatEntry;
    people: string[];
    anchor: DOMRect;
    onclose: () => void;
    onclosechat: () => void;
  } = $props();

  const app = $derived(appName(entry.app));
  const subtitle = $derived(entry.account ? `${app} \u00b7 ${entry.account}` : app);
  const canCall = $derived(canCallChat(entry.app, entry.isGroup));
  const rows = $derived(chatMenu(entry, onclosechat).flat());

  function startCall(kind: CallKind) {
    onclose();
    activeCall.start(entry, kind);
  }

  $effect(() => {
    const esc = (e: KeyboardEvent) => { if (e.key === "Escape") { e.stopPropagation(); onclose(); } };
    window.addEventListener("keydown", esc, true);
    return () => window.removeEventListener("keydown", esc, true);
  });
</script>

<!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
<div class="scrim" onclick={onclose}>
  <div class="panel" role="dialog" aria-label={entry.name} tabindex="-1" style:top="{anchor.bottom + 6}px" style:left="{Math.max(12, anchor.left)}px" onclick={(e) => e.stopPropagation()}>
    <div class="identity">
      <ChatFace id={entry.id} app={entry.app} name={entry.name} size={72} />
      <strong>{entry.name}</strong>
      <span class="sub">{subtitle}</span>
    </div>
    <div class="tiles">
      {#if canCall}
        <button class="tile" title={tr("Bel in {app}", "Call in {app}", { app })} onclick={() => startCall("voice")}>
          <CallIcon name="phone" size={16} />
          <span>{tr("Bel", "Call")}</span>
        </button>
        <button class="tile" title={tr("Bel in {app}", "Call in {app}", { app })} onclick={() => startCall("video")}>
          <CallIcon name="video" size={16} />
          <span>{tr("Video", "Video")}</span>
        </button>
      {/if}
      <button class="tile" title={tr("Open {app}", "Open {app}", { app })} onclick={() => { onclose(); activeCall.openApp(entry.app); }}>
        <Ico name="external-link" size={16} />
        <span>{app}</span>
      </button>
    </div>
    {#if entry.isGroup && people.length}
      <div class="section">
        <span class="label">{tr("Leden", "Members")} &middot; {people.length + 1}</span>
        <div class="card members">
          <span class="member">{tr("Jij", "You")}</span>
          {#each people as p (p)}<span class="member"><ChatFace id={p} app={entry.app} name={p} size={20} badge={false} />{p}</span>{/each}
        </div>
      </div>
    {/if}
    <div class="card">
      {#each rows as r (r.label)}
        <button class="row" class:danger={r.destructive} onclick={() => { r.onselect?.(); onclose(); }}>
          {#if r.icon}<Ico name={r.icon} size={14} />{/if}<span>{r.label}</span>
        </button>
      {/each}
    </div>
  </div>
</div>

<style>
  .scrim { position: fixed; inset: 0; z-index: 50; }
  .panel { position: fixed; width: 340px; max-height: min(600px, 80vh); overflow-y: auto; display: flex; flex-direction: column; gap: var(--space-12); padding: var(--space-12); box-sizing: border-box; background: var(--menu); border: 1px solid var(--line2); border-radius: var(--radius-panel); box-shadow: var(--shadow-popover); }
  .identity { display: flex; flex-direction: column; align-items: center; gap: var(--space-6); text-align: center; padding-top: var(--space-4); }
  .identity strong { font: var(--text-heading); color: var(--paper); user-select: text; }
  .sub { font: var(--text-detail); color: var(--text3); user-select: text; }
  .tiles { display: flex; gap: var(--space-8); }
  .tile { flex: 1; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: var(--space-4); padding: var(--space-8) var(--space-6); border: 0; border-radius: var(--radius-card); background: var(--smoke); color: var(--paper); font: var(--text-caption); }
  .tile:hover:not(:disabled) { background: var(--row-hover); }
  .section { display: flex; flex-direction: column; gap: var(--space-6); }
  .label { font: var(--text-label); color: var(--text2); }
  .card { display: flex; flex-direction: column; border-radius: var(--radius-card); background: var(--smoke); overflow: hidden; }
  .members { max-height: 180px; overflow-y: auto; padding: var(--space-4) 0; }
  .member { display: flex; align-items: center; gap: var(--space-8); padding: var(--space-4) var(--space-12); font: var(--text-control); font-weight: 400; color: var(--text-strong); }
  .row { display: flex; align-items: center; gap: var(--space-8); padding: var(--space-8) var(--space-12); border: 0; border-radius: 0; background: transparent; text-align: left; font: var(--text-control); font-weight: 400; color: var(--paper); }
  .row + .row { border-top: 1px solid var(--separator); }
  .row:hover:not(:disabled) { background: var(--row-hover); border-color: var(--separator); }
  .row.danger { color: var(--coral); }
</style>
