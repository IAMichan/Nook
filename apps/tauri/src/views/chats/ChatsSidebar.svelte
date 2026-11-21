<script lang="ts" module>
  /** An app in the sidebar: a chat app, or another linked app whose items the list shows (calendar, mail, GitHub). */
  export interface SidebarApp { id: string; title: string; domain: string | null; count: number }
  /** Whether the Chats tab shows the list of chats or the People directory (`ChatsMode` on the Mac). */
  export type ChatsMode = "chats" | "people";
</script>

<script lang="ts">
  // The Chats tab's sidebar (`ChatsSidebar`): the Chats / People switch on top, the views by where a chat stands, then
  // every app with chats here (the chosen one with its accounts under it, while it has more than one), then a way to
  // add one, and at the foot what the marks mean. In the main window it moves into the window's sidebar, under the
  // tabs, as the Mac's does.
  import { tr } from "../../lib/i18n.svelte";
  import { type ChatView, viewTitle } from "../../lib/chats-list";
  import Ico from "../../components/ui/Ico.svelte";
  import SectionLabel from "../../components/ui/SectionLabel.svelte";
  import ServiceIcon from "../connectors/ServiceIcon.svelte";

  let { mode = "chats", view, app, counts, apps, accounts = [], account = null, onmode, onview, onapp, onaccount, onadd }: {
    mode?: ChatsMode;
    view: ChatView;
    app: string | null;
    /** How many chats wait in a view (only New and Only in Nook show it). */
    counts: Partial<Record<ChatView, number>>;
    apps: SidebarApp[];
    /** The chosen app's accounts with what is new in each. */
    accounts?: { name: string; count: number }[];
    account?: string | null;
    onmode?: (m: ChatsMode) => void;
    onview: (v: ChatView) => void;
    onapp: (id: string | null) => void;
    onaccount?: (name: string | null) => void;
    onadd: () => void;
  } = $props();

  const views: ChatView[] = ["all", "unread", "readInNook", "read"];
</script>

<div class="chats-sidebar">
  {#if onmode}
    <div class="modes" role="tablist" aria-label={tr("Weergave", "View")}>
      <button type="button" role="tab" class="mode" class:on={mode === "chats"} aria-selected={mode === "chats"} onclick={() => onmode("chats")}>
        <Ico name="messages-square" size={13} stroke={2} />
        <span>{tr("Chats", "Chats")}</span>
      </button>
      <button type="button" role="tab" class="mode" class:on={mode === "people"} aria-selected={mode === "people"} onclick={() => onmode("people")}>
        <Ico name="users" size={13} stroke={2} />
        <span>{tr("Mensen", "People")}</span>
      </button>
    </div>
  {/if}
  <div class="rows">
    {#each views as v (v)}
      {@const count = v === "unread" || v === "readInNook" ? counts[v] ?? 0 : 0}
      <button class="row" class:on={mode === "chats" && view === v} aria-pressed={mode === "chats" && view === v} onclick={() => { onmode?.("chats"); onview(v); }}>
        <span class="glyph">
          {#if v === "all"}<Ico name="inbox" size={14} stroke={2} />
          {:else if v === "unread"}<span class="dot"></span>
          {:else if v === "readInNook"}<span class="tick"><Ico name="check" size={13} stroke={2.6} /></span>
          {:else}<span class="ticks"><Ico name="check-check" size={13} stroke={2.6} /></span>{/if}
        </span>
        <span class="title">{viewTitle(v)}</span>
        {#if count}<span class="count" class:quiet={v !== "unread"}>{count}</span>{/if}
      </button>
    {/each}
    {#if apps.length}
      <div class="apps-label"><SectionLabel text={tr("Apps", "Apps")} /></div>
      {#each apps as a (a.id)}
        <button class="row" class:on={mode === "chats" && app === a.id} aria-pressed={mode === "chats" && app === a.id} onclick={() => { onmode?.("chats"); onapp(app === a.id && mode === "chats" ? null : a.id); }}>
          <span class="glyph"><ServiceIcon domain={a.domain} title={a.title} size={15} /></span>
          <span class="title">{a.title}</span>
          {#if a.count}<span class="count">{a.count}</span>{/if}
        </button>
        {#if mode === "chats" && app === a.id}
          {#each accounts as acc (acc.name)}
            <button class="row account" class:on={account === acc.name} aria-pressed={account === acc.name} onclick={() => onaccount?.(account === acc.name ? null : acc.name)}>
              <span class="glyph"><Ico name="circle-user" size={13} stroke={2} /></span>
              <span class="title">{acc.name}</span>
              {#if acc.count}<span class="count">{acc.count}</span>{/if}
            </button>
          {/each}
        {/if}
      {/each}
    {/if}
    <button class="row muted add" onclick={onadd}>
      <span class="glyph"><Ico name="plus" size={13} stroke={2.4} /></span>
      <span class="title">{tr("Bron toevoegen", "Add a source")}</span>
    </button>
  </div>
  <!-- What the marks in the list mean, said once, quietly, at the foot. -->
  <div class="legend">
    <div class="line"><span class="mark"><span class="dot small"></span></span>{tr("Nieuw", "New")}</div>
    <div class="line"><span class="mark tick"><Ico name="check" size={12} stroke={2.6} /></span>{tr("Gelezen in Nook", "Read in Nook")}</div>
    <div class="line"><span class="mark ticks"><Ico name="check-check" size={12} stroke={2.6} /></span>{tr("Ook gelezen in de app", "Read in the app too")}</div>
  </div>
</div>

<style>
  .chats-sidebar { flex: 1; min-height: 0; display: flex; flex-direction: column; }
  .modes { flex: none; display: flex; gap: var(--space-2); padding: var(--space-2); margin: var(--space-4) 0 var(--space-6); background: var(--surface); border-radius: var(--radius-control); }
  .mode { flex: 1; display: inline-flex; align-items: center; justify-content: center; gap: var(--space-4); height: 26px; padding: 0 var(--space-6); border: 0; border-radius: var(--radius-chip); background: transparent; color: var(--text3); font: var(--text-label); white-space: nowrap; }
  .mode:hover:not(:disabled) { background: var(--row-hover); border: 0; color: var(--text2); }
  .mode.on { background: var(--row-selected); color: var(--paper); }
  .rows { flex: 1; min-height: 0; overflow-y: auto; display: flex; flex-direction: column; gap: var(--space-2); padding: var(--space-4) 0; }
  .row { display: flex; align-items: center; gap: var(--space-8); width: 100%; min-height: 30px; padding: 0 var(--space-8); border: 0; border-radius: var(--radius-control); background: transparent; text-align: left; color: var(--text-strong); }
  .row:hover:not(:disabled) { background: var(--row-hover); border: 0; }
  .row.on { background: var(--row-selected); color: var(--paper); }
  .row.muted { color: var(--text3); }
  .add { margin-top: var(--space-2); }
  .glyph { width: 18px; height: 18px; flex: none; display: grid; place-items: center; color: var(--text2); }
  .muted .glyph { color: var(--text3); }
  .title { flex: 1; min-width: 0; font: var(--text-label); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .count { font: var(--text-label); font-weight: 600; font-variant-numeric: tabular-nums; color: var(--amber); }
  .dot { width: 7px; height: 7px; border-radius: 50%; background: var(--amber); }
  .dot.small { width: 6px; height: 6px; }
  .ticks { display: inline-flex; color: var(--mint); }
  .tick { display: inline-flex; color: var(--text2); }
  .legend .tick { color: var(--text3); }
  .count.quiet { color: var(--text3); }
  .account { padding-left: calc(var(--space-8) + var(--space-12)); }
  .apps-label { padding-top: var(--space-12); }
  .apps-label :global(.section-label) { font: var(--text-label); padding: 0 var(--space-8) var(--space-4); }
  .legend { flex: none; display: flex; flex-direction: column; gap: var(--space-6); padding: var(--space-8) var(--space-8); border-top: 1px solid var(--hairline); margin-top: var(--space-4); }
  .line { display: flex; align-items: center; gap: var(--space-6); font: var(--text-caption); color: var(--text3); }
  .mark { width: 18px; display: grid; place-items: center; }
</style>
