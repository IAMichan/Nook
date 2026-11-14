<script lang="ts">
  // The Chats tab of the iPhone app (`InboxListView`): every chat app on the computer in one list, newest first, with a
  // search and All / Unread once there are more than eight. WhatsApp chats read as WhatsApp; the rest as Nook's rows.
  import { chatTime, companion, filterInbox, has, typingText, Feature, type ClientView, type InboxChatDigest } from "../../lib/companion";
  import { tr } from "../../lib/i18n.svelte";
  import PanelHeader from "./ui/PanelHeader.svelte";
  import ConnectionLine from "./ui/ConnectionLine.svelte";
  import SearchField from "./ui/SearchField.svelte";
  import InboxAvatar from "./ui/InboxAvatar.svelte";
  import TicksMark from "./ui/TicksMark.svelte";
  import EmptyState from "./ui/EmptyState.svelte";
  import Banner from "./ui/Banner.svelte";
  import Menu, { type MenuItem } from "./ui/Menu.svelte";
  import { WA } from "./ui/whatsapp";

  let { view, inbox, message, onorb, ongear, onopen, took, onrefresh }: {
    view: ClientView; inbox: InboxChatDigest[]; message?: string; onorb: (r: DOMRect) => void; ongear: () => void;
    onopen: (id: string) => void; took: (v: ClientView) => void; onrefresh: () => void;
  } = $props();
  let query = $state("");
  let unreadOnly = $state(false);
  let header = $state<HTMLDivElement | null>(null);
  let menu = $state<{ chat: InboxChatDigest; anchor: DOMRect } | null>(null);
  const chats = $derived(filterInbox(inbox, query, unreadOnly));
  const unreadCount = $derived(inbox.filter((c) => c.unread > 0).length);
  let press: ReturnType<typeof setTimeout> | undefined;
  let held = false;

  function down(e: PointerEvent, chat: InboxChatDigest) {
    held = false;
    const el = e.currentTarget as HTMLElement;
    press = setTimeout(() => { held = true; menu = { chat, anchor: el.getBoundingClientRect() }; }, 450);
  }
  const up = () => clearTimeout(press);

  async function mark(chat: InboxChatDigest, read: boolean) {
    const r = await companion.call({ op: "inboxMark", item: chat.id, allow: read });
    took(r.view);
    onrefresh();
  }
  const menuSections = $derived<MenuItem[][]>(menu ? [[
    menu.chat.unread > 0 || menu.chat.waitsInApp
      ? { label: tr("Markeer als gelezen", "Mark as read"), icon: "mail-open", onselect: () => menu && mark(menu.chat, true) }
      : { label: tr("Markeer als ongelezen", "Mark as unread"), icon: "mail", onselect: () => menu && mark(menu.chat, false) },
  ]] : []);
</script>

<div class="tab">
  <div class="scroll">
    <div bind:this={header}>
      <PanelHeader title={tr("Chats", "Chats")} {view} onorb={() => header && onorb((header.querySelector(".orb") as HTMLElement).getBoundingClientRect())} {ongear} />
    </div>
    <div class="top">
      <ConnectionLine {view} />
      {#if !has(view, Feature.inbox)}
        <EmptyState icon="circle-arrow-down" title={tr("Werk Nook op je Mac bij", "Update Nook on your Mac")} text={tr("Werk Nook op je Mac bij om je chats op je telefoon te lezen en te beantwoorden.", "Update Nook on your Mac to read and answer your chats from your phone.")} />
      {:else}
        {#if message === "chatsaccess"}<Banner icon="lock">{tr("Nook kan de meldingen op je Mac niet lezen: geef het Volledige schijftoegang in Systeeminstellingen.", "Nook cannot read the notifications on your Mac: give it Full Disk Access in System Settings.")}</Banner>{/if}
        {#if !inbox.length && view.phase === "connected"}
          {#if message === "chatsoff"}
            <EmptyState icon="messages-square" title={tr("Chats staan uit op je Mac", "Chats are off on your Mac")} text={tr("Koppel WhatsApp of zet Chats aan in Nook › Instellingen › Koppelingen om hier al je chats te zien.", "Link WhatsApp or turn on Chats in Nook › Settings › Connections to see every chat here.")} />
          {:else}
            <EmptyState icon="messages-square" title={tr("Nog geen chats", "No chats yet")} text={tr("Nieuwe berichten uit WhatsApp en je andere chatapps op je Mac verschijnen hier.", "New messages from WhatsApp and your other chat apps on your Mac show up here.")} />
          {/if}
        {/if}
        {#if inbox.length > 8}
          <SearchField bind:value={query} placeholder={tr("Zoek chats", "Search chats")} />
          <div class="chips">
            <button class="chip" class:on={!unreadOnly} onclick={() => (unreadOnly = false)}>{tr("Alles", "All")}</button>
            <button class="chip" class:on={unreadOnly} onclick={() => (unreadOnly = true)}>{tr("Ongelezen", "Unread")}{#if unreadCount}<span class="n">{unreadCount}</span>{/if}</button>
          </div>
        {/if}
        {#if inbox.length && !chats.length}<p class="none">{unreadOnly ? tr("Niets ongelezen.", "Nothing unread.") : tr("Geen chat gevonden.", "No chat matches.")}</p>{/if}
      {/if}
    </div>
    <div class="rows">
      {#each chats as c, i (c.id)}
        {#if i > 0}<div class="rule"></div>{/if}
        {@const typing = typingText(c.typing)}
        {#if c.app === "whatsapp"}
          <button class="row wa row-press" onclick={() => !held && onopen(c.id)} onpointerdown={(e) => down(e, c)} onpointerup={up} onpointerleave={up} onpointercancel={up} oncontextmenu={(e) => e.preventDefault()}>
            <InboxAvatar name={c.name} size={52} badge={false} />
            <span class="text">
              <span class="l1"><strong style:color={WA.text}>{c.name}</strong><span class="when" style:color={c.unread ? WA.green : WA.quiet}>{chatTime(c.last)}</span></span>
              <span class="l2">
                {#if typing}<span class="prev" style:color={WA.green}>{typing}</span>
                {:else}<span class="prev" style:color={WA.quiet}>{#if c.ticks}<TicksMark ticks={c.ticks} read={WA.readTick} quiet={WA.quiet} /> {/if}{c.preview || c.appName}</span>{/if}
                {#if c.unread}<span class="wacount">{c.unread > 99 ? "99+" : c.unread}</span>{/if}
              </span>
            </span>
          </button>
        {:else}
          <button class="row row-press" onclick={() => !held && onopen(c.id)} onpointerdown={(e) => down(e, c)} onpointerup={up} onpointerleave={up} onpointercancel={up} oncontextmenu={(e) => e.preventDefault()}>
            <InboxAvatar name={c.name} app={c.app} size={40} />
            <span class="text">
              <span class="l1"><strong class:unread={c.unread > 0}>{c.name}</strong><span class="when" class:unread={c.unread > 0}>{chatTime(c.last)}</span></span>
              <span class="l2">
                {#if typing}<span class="prev" style:color="var(--mint)">{typing}</span>
                {:else}<span class="prev two" class:unread={c.unread > 0}>{#if c.ticks}<TicksMark ticks={c.ticks} /> {/if}{c.preview || c.appName}</span>{/if}
                {#if c.unread}<span class="count">{c.unread}</span>{/if}
              </span>
            </span>
          </button>
        {/if}
      {/each}
    </div>
  </div>
</div>
{#if menu}<Menu sections={menuSections} anchor={menu.anchor} onclose={() => (menu = null)} />{/if}

<style>
  .tab { flex: 1; min-height: 0; display: flex; flex-direction: column; }
  .scroll { flex: 1; overflow-y: auto; padding-bottom: 24px; }
  .top { display: flex; flex-direction: column; gap: 12px; padding: 0 16px 8px; }
  .chips { display: flex; gap: 4px; }
  .chip { display: inline-flex; align-items: center; gap: 4px; padding: 7px 10px !important; border-radius: 8px; background: var(--smoke) !important; color: var(--text-strong) !important; font: var(--pt-label) !important; }
  .chip.on { background: var(--iris) !important; color: var(--on-iris) !important; }
  .n { font: 500 12.57px ui-rounded, var(--font); opacity: 0.7; }
  .none { margin: 0; padding: 24px 0; text-align: center; font: var(--pt-body); color: var(--text2); }
  .rows { padding: 0 8px; }
  .rule { height: 1px; background: var(--separator); margin: 2px 12px; }
  .row { width: 100%; display: flex; align-items: center; gap: 12px; padding: 12px; text-align: left; -webkit-touch-callout: none; user-select: none; }
  .row.wa { padding: 8px 12px; }
  .text { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 2px; }
  .l1 { display: flex; align-items: baseline; gap: 8px; }
  .l1 strong { flex: 1; min-width: 0; font: var(--pt-strong); color: var(--text-strong); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .l1 strong.unread { color: var(--paper); }
  .wa .l1 strong { font: 500 17px var(--font); }
  .when { font: var(--pt-caption); font-variant-numeric: tabular-nums; color: var(--text3); flex: none; }
  .when.unread { color: var(--amber); }
  .wa .when { font: 400 12px var(--font); }
  .l2 { display: flex; align-items: center; gap: 6px; }
  .prev { flex: 1; min-width: 0; font: var(--pt-detail); color: var(--text2); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .prev.two { white-space: normal; display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; }
  .prev.unread { color: var(--text-strong); }
  .wa .prev { font: 400 15px var(--font); }
  .count { min-width: 16px; height: 16px; padding: 0 4px; border-radius: 6px; background: rgba(240, 182, 90, 0.14); color: var(--amber); font: 600 11.4px ui-rounded, var(--font); display: inline-flex; align-items: center; justify-content: center; flex: none; }
  .wacount { min-width: 20px; height: 20px; padding: 0 6px; border-radius: 999px; background: #00a884; color: #0b141a; font: 600 12px var(--font); display: inline-flex; align-items: center; justify-content: center; box-sizing: border-box; flex: none; }
</style>
