<script lang="ts">
  // A chat in the list (`ChatsRow`, `ChatListRowContent`): its picture with its app's mark, its name, when, the newest
  // message, and where it stands at the end of that line: the count of what is new, one grey tick for read in Nook.
  // Under the pointer its one step shows where its time was (`ChatsRowAction`); a right-click opens its menu. The same
  // row for every chat app.
  import { appName, clockOrDay, typingLine, type ChatEntry } from "../../lib/chats-list";
  import { tr } from "../../lib/i18n.svelte";
  import CountBadge from "../../components/ui/CountBadge.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import Menu from "../../components/ui/Menu.svelte";
  import ChatFace from "./ChatFace.svelte";
  import Ticks from "./Ticks.svelte";
  import { chatMenu, markReadInApp, markReadInNook, markUnread } from "./chat-actions.svelte";

  let { entry, selected, now, onselect, onclosed }: { entry: ChatEntry; selected: boolean; now: Date; onselect: () => void; onclosed?: () => void } = $props();
  let hovering = $state(false);
  let menuAt = $state<DOMRect | null>(null);
  const unread = $derived(entry.read === "unread");
  const app = $derived(appName(entry.app));
  const typing = $derived(typingLine(entry.typing, entry.isGroup, entry.name));
  // Where the click takes it: what is new read in Nook (WhatsApp reads in the app at once), read in Nook passed on to
  // the app, and read everywhere unread again.
  const step = $derived(
    entry.read === "unread"
      ? { title: tr("Gelezen", "Read"), help: tr("Gelezen in Nook", "Read in Nook"), mark: "check" as const, run: () => (entry.app === "whatsapp" ? markReadInApp(entry) : markReadInNook(entry)) }
      : entry.read === "readInNook"
        ? { title: tr("Gelezen in {app}", "Read in {app}", { app }), help: tr("Markeer gelezen in {app}", "Mark as read in {app}", { app }), mark: "check-check" as const, run: () => markReadInApp(entry) }
        : { title: tr("Ongelezen", "Unread"), help: tr("Markeer als ongelezen", "Mark as unread"), mark: "dot" as const, run: () => markUnread(entry) },
  );
  const label = $derived(`${app}, ${entry.name}${unread ? `, ${tr("{n} nieuw", "{n} new", { n: entry.unread })}` : entry.read === "readInNook" ? `, ${tr("Gelezen in Nook", "Read in Nook")}` : ""}: ${typing ?? entry.preview}`);
</script>

<div class="wrap" role="presentation" onmouseenter={() => (hovering = true)} onmouseleave={() => (hovering = false)}
  oncontextmenu={(e) => { e.preventDefault(); menuAt = new DOMRect(e.clientX, e.clientY, 0, 0); }}>
  <button class="row" class:selected class:unread class:hovered={hovering} aria-current={selected ? "true" : undefined} aria-label={label} onclick={onselect}>
    <ChatFace id={entry.id} app={entry.app} name={entry.name} size={40} />
    <span class="what">
      <span class="top">
        <span class="name">{entry.name}</span>
        {#if entry.account}<span class="detail" class:hidden={hovering}>{entry.account}</span>{/if}
        <span class="when" class:hidden={hovering}>{clockOrDay(entry.last, now)}</span>
      </span>
      <span class="bottom">
        {#if typing}
          <span class="preview typing">{typing}</span>
        {:else}
          {#if entry.ticks}<Ticks receipt={entry.ticks} size={12} />{/if}
          <span class="preview">{entry.preview || " "}</span>
        {/if}
        {#if unread}<CountBadge count={entry.unread} />{:else if entry.read === "readInNook" && !entry.lastIsMine}<span class="grey" title={tr("Gelezen in Nook", "Read in Nook")}><Ico name="check" size={11} stroke={2.8} /></span>{/if}
      </span>
    </span>
  </button>
  {#if hovering}
    <button class="read" title={step.help} aria-label={step.help} onclick={step.run}>
      {#if step.mark === "dot"}<span class="dot"></span>{:else}<span class:mint={step.mark === "check-check"} class:grey={step.mark === "check"}><Ico name={step.mark} size={11} stroke={2.8} /></span>{/if}
      {step.title}
    </button>
  {/if}
</div>
{#if menuAt}<Menu sections={chatMenu(entry, onclosed)} anchor={menuAt} onclose={() => (menuAt = null)} />{/if}

<style>
  .wrap { position: relative; }
  .row { display: flex; align-items: center; gap: var(--space-8); width: 100%; padding: var(--space-8) var(--space-12); border: 0; border-radius: var(--radius-card); background: transparent; text-align: left; color: inherit; }
  .row:hover:not(:disabled), .row.hovered { background: var(--row-hover); border: 0; }
  .row.selected, .row.selected:hover:not(:disabled) { background: var(--row-selected); }
  .hidden { visibility: hidden; }
  /* `ChatMarkButton`, compact: the row's step under the pointer, where its time was. */
  .read { position: absolute; top: var(--space-6); right: var(--space-6); display: inline-flex; align-items: center; gap: var(--space-4); height: 22px; padding: 0 var(--space-8); border: 1px solid var(--separator); border-radius: var(--radius-control); background: var(--surface); color: var(--text-strong); font: var(--text-caption); font-weight: 600; }
  .read:hover:not(:disabled) { background: var(--smoke); border-color: var(--separator); color: var(--paper); }
  .mint { display: inline-flex; color: var(--mint); }
  .grey { display: inline-flex; color: var(--text3); }
  .dot { width: 6px; height: 6px; border-radius: 50%; background: var(--amber); }
  .what { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: var(--space-2); }
  .top, .bottom { display: flex; align-items: center; gap: var(--space-6); min-width: 0; }
  .top { align-items: baseline; }
  .name { flex: 1; min-width: 0; font: var(--text-emphasis); line-height: 1.3; color: var(--text-strong); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .unread .name { color: var(--paper); }
  .detail { flex: none; max-width: 40%; font: var(--text-caption); color: var(--text3); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .when { flex: none; font: var(--text-caption); font-variant-numeric: tabular-nums; color: var(--text3); }
  .unread .when { color: var(--amber); }
  .preview { flex: 1; min-width: 0; font: var(--text-detail); color: var(--text2); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .unread .preview { color: var(--text-strong); }
  .preview.typing, .unread .preview.typing { color: var(--mint); }
</style>
