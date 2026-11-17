<script lang="ts">
  // The Chats tab of the iPhone app (`InboxListView`): every chat app on the computer in one list, newest first, with a
  // search and All / Unread once there are more than eight. WhatsApp chats read as WhatsApp; the rest as Nook's rows.
  // A computer with `chatActions` gives the Mac's Chats tab instead: the list grouped Pinned / Today / Yesterday / This
  // week / This month / Earlier, filters by read state and app (with an app's Status and Channels), a search on the
  // computer, and a menu per chat with what its app takes.
  import {
    chatApps, chatKinds, chatTime, companion, filterChats, filterInbox, groupChats, groupTitle, has, kindTitle, readState, typingText, Feature,
    type ClientView, type InboxChatDigest, type ReadState,
  } from "../../lib/companion";
  import { act, chatMenu, type ChatConfirm } from "./chat-actions";
  import Dialog from "./ui/Dialog.svelte";
  import Ico from "./ui/Ico.svelte";
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
  import { fetchPictures } from "../../lib/avatars.svelte";

  let { view, inbox, message, onorb, oncomputers, ongear, onopen, took, onrefresh }: {
    view: ClientView; inbox: InboxChatDigest[]; message?: string; onorb: (r: DOMRect) => void; oncomputers?: (r: DOMRect) => void; ongear: () => void;
    onopen: (id: string) => void; took: (v: ClientView) => void; onrefresh: () => void;
  } = $props();
  let query = $state("");
  let unreadOnly = $state(false);
  let header = $state<HTMLDivElement | null>(null);
  let menu = $state<{ chat: InboxChatDigest; anchor: DOMRect } | null>(null);
  const rich = $derived(has(view, Feature.chatActions));
  let read = $state<ReadState | null>(null);
  let app = $state<string | null>(null);
  let kind = $state("chats");
  let found = $state<InboxChatDigest[] | null>(null);
  let searching = $state(false);
  let confirming = $state<ChatConfirm | null>(null);
  const apps = $derived(chatApps(inbox));
  const kinds = $derived(chatKinds(inbox, app));
  $effect(() => { if (!kinds.includes(kind)) kind = "chats"; });
  const chats = $derived(rich ? filterChats(inbox, { read, app, kind }) : filterInbox(inbox, query, unreadOnly));
  const groups = $derived(groupChats(chats));
  const counts = $derived({
    unread: filterChats(inbox, { app, kind, read: "unread" }).length,
    readInNook: filterChats(inbox, { app, kind, read: "readInNook" }).length,
  });
  // The search on the computer (`inboxSearch`): its names, people and messages, a moment after you stop typing.
  $effect(() => {
    const words = query.trim();
    if (!rich || words.length < 2) { found = null; searching = false; return; }
    searching = true;
    const timer = setTimeout(async () => {
      const r = await companion.call({ op: "inboxSearch", text: words });
      if (query.trim() !== words) return;
      searching = false;
      found = r.response?.inboxFound ?? [];
      if (!r.response) took(r.view);
    }, 300);
    return () => clearTimeout(timer);
  });
  async function run(chat: InboxChatDigest, action: Parameters<typeof act>[1]) {
    const r = await act(chat.id, action);
    took(r.view);
    onrefresh();
  }
  const emptyRead = $derived(
    read === "unread" ? tr("Niets ongelezen.", "Nothing unread.")
    : read === "readInNook" ? tr("Geen chat is alleen in Nook gelezen.", "No chat is read only in Nook.")
    : read === "read" ? tr("Nog geen chat is overal gelezen.", "No chat is read everywhere yet.")
    : tr("Geen chat gevonden.", "No chat matches."),
  );
  $effect(() => { void fetchPictures(view, inbox); });
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
  const menuSections = $derived<MenuItem[][]>(menu && rich ? chatMenu(menu.chat, (a) => menu && run(menu.chat, a), (c) => (confirming = c), undefined) : menu ? [[
    menu.chat.unread > 0 || menu.chat.waitsInApp
      ? { label: tr("Markeer als gelezen", "Mark as read"), icon: "mail-open", onselect: () => menu && mark(menu.chat, true) }
      : { label: tr("Markeer als ongelezen", "Mark as unread"), icon: "mail", onselect: () => menu && mark(menu.chat, false) },
  ]] : []);
</script>

<div class="tab">
  <div class="scroll">
    <div bind:this={header}>
      <PanelHeader title={tr("Chats", "Chats")} {view} onorb={() => header && onorb((header.querySelector(".orb") as HTMLElement).getBoundingClientRect())} {oncomputers} {ongear} />
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
        {#if rich && (inbox.length || query)}
          <SearchField bind:value={query} placeholder={tr("Zoek chats en berichten", "Search chats and messages")} />
          {#if found === null}
            <div class="chips">
              {#each [[null, tr("Alles", "All")], ["unread", tr("Nieuw", "New")], ["readInNook", tr("Alleen in Nook", "Only in Nook")], ["read", tr("Gelezen", "Read")]] as [value, label] (label)}
                <button class="chip" class:on={read === value} onclick={() => (read = value as ReadState | null)}>{label}{#if value === "unread" && counts.unread}<span class="n">{counts.unread}</span>{:else if value === "readInNook" && counts.readInNook}<span class="n">{counts.readInNook}</span>{/if}</button>
              {/each}
            </div>
            {#if apps.length > 1}
              <div class="chips scrollx">
                <button class="chip" class:on={!app} onclick={() => (app = null)}>{tr("Elke app", "Every app")}</button>
                {#each apps as a (a.app)}<button class="chip" class:on={app === a.app} onclick={() => (app = a.app)}>{a.name}</button>{/each}
              </div>
            {/if}
            {#if kinds.length}
              <div class="segments">{#each kinds as k (k)}<button class="segment" class:on={kind === k} onclick={() => (kind = k)}>{kindTitle(k)}</button>{/each}</div>
            {/if}
          {/if}
        {:else if !rich && inbox.length > 8}
          <SearchField bind:value={query} placeholder={tr("Zoek chats", "Search chats")} />
          <div class="chips">
            <button class="chip" class:on={!unreadOnly} onclick={() => (unreadOnly = false)}>{tr("Alles", "All")}</button>
            <button class="chip" class:on={unreadOnly} onclick={() => (unreadOnly = true)}>{tr("Ongelezen", "Unread")}{#if unreadCount}<span class="n">{unreadCount}</span>{/if}</button>
          </div>
        {/if}
        {#if rich && found !== null}
          {#if searching && !found.length}<p class="none">{tr("Zoeken…", "Searching…")}</p>
          {:else if !found.length}<p class="none">{tr("Geen chat gevonden.", "No chat matches.")}</p>{/if}
        {:else if rich && inbox.length && !chats.length}<p class="none">{emptyRead}</p>
        {:else if !rich && inbox.length && !chats.length}<p class="none">{unreadOnly ? tr("Niets ongelezen.", "Nothing unread.") : tr("Geen chat gevonden.", "No chat matches.")}</p>{/if}
      {/if}
    </div>
    {#if rich && found !== null}
      <div class="rows">{#each found as c, i (c.id)}{@render row(c, i)}{/each}</div>
    {:else if rich}
      {#each groups as g (g.group)}
        <h3 class="group">{#if g.group === "pinned"}<Ico name="pin" size={11} />{/if}{groupTitle(g.group)}</h3>
        <div class="rows">{#each g.chats as c, i (c.id)}{@render row(c, i)}{/each}</div>
      {/each}
    {:else}
      <div class="rows">{#each chats as c, i (c.id)}{@render row(c, i)}{/each}</div>
    {/if}
  </div>
</div>

{#snippet row(c: InboxChatDigest, i: number)}
        {#if i > 0}<div class="rule"></div>{/if}
        {@const typing = typingText(c.typing)}
        {#if c.app === "whatsapp"}
          <button class="row wa row-press" onclick={() => !held && onopen(c.id)} onpointerdown={(e) => down(e, c)} onpointerup={up} onpointerleave={up} onpointercancel={up} oncontextmenu={(e) => e.preventDefault()}>
            <InboxAvatar id={c.id} name={c.name} size={52} badge={false} />
            <span class="text">
              <span class="l1"><strong style:color={WA.text}>{c.name}</strong>{@render marks(c)}<span class="when" style:color={c.unread ? WA.green : WA.quiet}>{chatTime(c.last)}</span></span>
              <span class="l2">
                {#if typing}<span class="prev" style:color={WA.green}>{typing}</span>
                {:else}<span class="prev" style:color={WA.quiet}>{#if c.ticks}<TicksMark ticks={c.ticks} read={WA.readTick} quiet={WA.quiet} /> {/if}{c.preview || c.appName}</span>{/if}
                {#if c.unread}<span class="wacount">{c.unread > 99 ? "99+" : c.unread}</span>{/if}
              </span>
            </span>
          </button>
        {:else}
          <button class="row row-press" onclick={() => !held && onopen(c.id)} onpointerdown={(e) => down(e, c)} onpointerup={up} onpointerleave={up} onpointercancel={up} oncontextmenu={(e) => e.preventDefault()}>
            <InboxAvatar id={c.id} name={c.name} app={c.app} size={40} />
            <span class="text">
              <span class="l1"><strong class:unread={c.unread > 0}>{c.name}</strong>{@render marks(c)}<span class="when" class:unread={c.unread > 0}>{chatTime(c.last)}</span></span>
              <span class="l2">
                {#if typing}<span class="prev" style:color="var(--mint)">{typing}</span>
                {:else}<span class="prev two" class:unread={c.unread > 0}>{#if c.ticks}<TicksMark ticks={c.ticks} /> {/if}{c.preview || c.appName}</span>{/if}
                {#if c.unread}<span class="count">{c.unread}</span>{/if}
              </span>
            </span>
          </button>
        {/if}
{/snippet}

{#snippet marks(c: InboxChatDigest)}
  {#if rich}
    {#if c.account}<span class="mark account">{c.account}</span>{/if}
    {#if c.mutedInApp}<span class="mark" title={tr("Gedempt", "Muted")}><Ico name="bell-off" size={12} /></span>{/if}
    {#if c.pinnedInApp && !c.pinned}<span class="mark"><Ico name="pin" size={12} /></span>{/if}
    {#if readState(c) === "readInNook"}<span class="mark" title={tr("Gelezen in Nook", "Read in Nook")}><Ico name="eye" size={12} /></span>{/if}
  {/if}
{/snippet}
{#if menu}<Menu sections={menuSections} anchor={menu.anchor} title={rich ? menu.chat.name : undefined} onclose={() => (menu = null)} />{/if}
{#if confirming}{@const c = confirming}
  <Dialog title={c.title} message={c.message} onclose={() => (confirming = null)}
    buttons={[{ label: c.button, destructive: true, onselect: c.run }, { label: tr("Annuleer", "Cancel"), bold: true, onselect: () => {} }]} />
{/if}

<style>
  .tab { flex: 1; min-height: 0; display: flex; flex-direction: column; }
  .scroll { flex: 1; overflow-y: auto; padding-bottom: 24px; }
  .top { display: flex; flex-direction: column; gap: 12px; padding: 0 16px 8px; }
  .chips { display: flex; gap: 4px; flex-wrap: wrap; }
  .chips.scrollx { flex-wrap: nowrap; overflow-x: auto; scrollbar-width: none; }
  .chips.scrollx::-webkit-scrollbar { display: none; }
  .chips.scrollx .chip { flex: none; }
  .segments { display: flex; padding: 2px; border-radius: 9px; background: var(--smoke); }
  .segment { flex: 1; padding: 6px 8px !important; border-radius: 7px; font: var(--pt-label) !important; color: var(--text2) !important; }
  .segment.on { background: var(--surface) !important; color: var(--text-strong) !important; }
  .group { display: flex; align-items: center; gap: 4px; margin: 12px 0 2px; padding: 0 20px; font: var(--pt-label); color: var(--text3); }
  .mark { display: inline-flex; align-items: center; color: var(--text3); flex: none; }
  .mark.account { font: var(--pt-caption); max-width: 90px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
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
