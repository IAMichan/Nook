<script lang="ts">
  // "For you" on the empty Nook chat (the Today rows of `NookTab` on the Mac): the few things the inbox ranks highest,
  // up to six, in one card. Each row has the icon of where it comes from, its title and line, and its action.
  import { inbox } from "../lib/inbox.svelte";
  import type { InboxItem, InboxSource, Target } from "../lib/inbox";
  import Icon from "./Icon.svelte";

  let { items, onopen }: { items: InboxItem[]; onopen: (target: Target | void) => void } = $props();

  type IconName = "agents" | "chat" | "tasks" | "calendar" | "message" | "code" | "gamepad" | "note" | "sparkle" | "home";
  const icons: Record<InboxSource, IconName> = {
    agents: "agents", chats: "chat", tasks: "tasks", calendar: "calendar", messages: "message",
    code: "code", gamer_mode: "gamepad", notes: "note", ai: "sparkle", system: "home",
  };
  // The color of what kind of thing it is: amber needs you, mint you missed, the rest quiet.
  const tint = (item: InboxItem) => (item.type === "action_required" ? "var(--amber)" : item.type === "missed" ? "var(--mint)" : "var(--text2)");

  let busy = $state<string | null>(null);
  async function run(item: InboxItem) {
    const action = item.actions[0];
    if (!action) return;
    busy = item.id;
    try {
      onopen(await inbox.act(item, action.id));
    } finally {
      busy = null;
    }
  }
</script>

<div class="card">
  {#each items as item (item.id)}
    <button class="row" onclick={() => run(item)} disabled={busy === item.id || !item.actions.length}>
      <span class="logo" style:color={tint(item)}><Icon name={icons[item.source]} size={14} /></span>
      <span class="text">
        <span class="title">{item.title}</span>
        {#if item.detail}<span class="detail">{item.detail}</span>{/if}
      </span>
      {#if item.actions[0]}<span class="action">{item.actions[0].label}<Icon name="chevron-right" size={11} /></span>{/if}
    </button>
  {/each}
</div>

<style>
  .card { display: flex; flex-direction: column; background: var(--field); border-radius: var(--radius-panel); overflow: hidden; }
  .row { display: flex; align-items: center; gap: var(--space-12); padding: var(--space-12) 14px; text-align: left; background: transparent; border: 0; border-radius: 0; color: var(--paper); }
  .row { position: relative; }
  .row + .row::before { content: ""; position: absolute; top: 0; left: 56px; right: 0; height: 1px; background: var(--hairline); }
  .row:hover:not(:disabled) { background: var(--row-hover); border-color: transparent; }
  .row:disabled { opacity: 1; cursor: default; }
  .logo { display: grid; place-items: center; width: 30px; height: 30px; flex: none; border-radius: var(--radius-control); background: color-mix(in srgb, currentColor 12%, transparent); }
  .text { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: var(--space-2); }
  .title { font: var(--text-body); font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .detail { font: var(--text-detail); color: var(--text2); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .action { display: flex; align-items: center; gap: var(--space-4); flex: none; font: var(--text-label); color: var(--text3); }
  .row:hover .action { color: var(--paper); }
</style>
