<script lang="ts">
  // Home's inbox: the few items `inbox` ranks highest, each with its source's own action and a quiet dismiss. Calmer
  // items wait behind "n more"; nothing here is red or counts up.
  import { fly, fade, slide } from "svelte/transition";
  import { flip } from "svelte/animate";
  import { cubicOut } from "svelte/easing";
  import Icon from "../../components/Icon.svelte";
  import { inbox } from "../../lib/inbox.svelte";
  import type { InboxItem, InboxSource, Target } from "../../lib/inbox";
  import { relativeTime } from "../../lib/state.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import { digestFor, FOCUS_MODES, type FocusMode, type SnoozeChoice } from "../../lib/attention";

  let { onopen, compact = false }: { onopen: (target: Target | void) => void; compact?: boolean } = $props();

  let expanded = $state(false);
  let busy = $state<string | null>(null);
  /// "inbox" is the list; "catchup" the summary since you last looked; "history" everything seen so far.
  let view = $state<"inbox" | "catchup" | "history">("inbox");
  let snoozing = $state<string | null>(null);

  const focusLabels: Record<FocusMode, [string, string]> = {
    all: ["Alles", "Everything"],
    work: ["Werk", "Work"],
    deep: ["Diep werk", "Deep work"],
    off_hours: ["Buiten werktijd", "Off hours"],
  };
  const snoozeChoices: [SnoozeChoice, [string, string]][] = [
    ["hour", ["Over een uur", "In 1 hour"]],
    ["tomorrow", ["Morgenochtend", "Tomorrow morning"]],
    ["week", ["Volgende week", "Next week"]],
  ];
  const digest = $derived(digestFor(new Date().getHours()));
  const catchTitle = $derived(
    digest === "morning" ? tr("Ochtendoverzicht", "Morning brief") : digest === "evening" ? tr("Avondoverzicht", "Evening wrap-up") : tr("Even bijpraten", "Catch me up"),
  );

  async function done() {
    await inbox.markSeen();
    view = "inbox";
  }
  async function snooze(item: InboxItem, choice: SnoozeChoice) {
    snoozing = null;
    await inbox.snooze(item.id, choice);
  }

  const sources: Record<InboxSource, { icon: "agents" | "chat" | "tasks" | "calendar" | "message" | "code" | "gamepad" | "note" | "sparkle" | "home"; label: [string, string] }> = {
    agents: { icon: "agents", label: ["Agents", "Agents"] },
    chats: { icon: "chat", label: ["Chat", "Chat"] },
    tasks: { icon: "tasks", label: ["Open punt", "Open item"] },
    calendar: { icon: "calendar", label: ["Agenda", "Calendar"] },
    messages: { icon: "message", label: ["WhatsApp", "WhatsApp"] },
    code: { icon: "code", label: ["Pull request", "Pull request"] },
    gamer_mode: { icon: "gamepad", label: ["Gamer Mode", "Gamer Mode"] },
    notes: { icon: "note", label: ["Notitie", "Note"] },
    ai: { icon: "sparkle", label: ["Meedenken", "Think Along"] },
    system: { icon: "home", label: ["Nook", "Nook"] },
  };

  const shown = $derived(expanded ? [...inbox.ranked.shown, ...inbox.ranked.rest] : inbox.ranked.shown);
  const more = $derived(inbox.ranked.rest.length);

  /// A reminder shows when it is due (in its detail); everything else when it happened.
  const time = (item: InboxItem) => (item.type === "reminder" ? "" : relativeTime(item.at));

  async function run(item: InboxItem, action: string) {
    busy = item.id;
    try {
      onopen(await inbox.act(item, action));
    } finally {
      busy = null;
    }
  }
</script>

<div class="card" class:compact>
  <div class="head">
    <span class="eyebrow">{tr("Inbox", "Inbox")}</span>
    <button class="ghost tab first" class:on={view === "catchup"} onclick={() => (view = view === "catchup" ? "inbox" : "catchup")} aria-pressed={view === "catchup"}>{catchTitle}</button>
    <button class="ghost tab" class:on={view === "history"} onclick={() => (view = view === "history" ? "inbox" : "history")} aria-pressed={view === "history"}>{tr("Geschiedenis", "History")}</button>
    {#if !inbox.loading && shown.length && view === "inbox"}<button class="ghost refresh" onclick={() => inbox.refresh()} title={tr("Opnieuw kijken", "Look again")}>{tr("Vernieuwen", "Refresh")}</button>{/if}
  </div>

  <div class="focus" role="group" aria-label={tr("Focus", "Focus")}>
    {#each FOCUS_MODES as mode (mode)}
      <button class="ghost chipbtn" class:on={inbox.focus === mode} aria-pressed={inbox.focus === mode} onclick={() => inbox.setFocus(mode)}>{tr(...focusLabels[mode])}</button>
    {/each}
  </div>

  {#if view === "catchup"}
    <div class="panel" in:fade={{ duration: 200 }}>
      {#if inbox.summary.total === 0}
        <strong>{tr("Je bent helemaal bij.", "You're all caught up.")}</strong>
        <span class="faint">{tr("Sinds je voor het laatst keek is er niets nieuws.", "Nothing new since you last looked.")}</span>
      {:else}
        <strong>{inbox.summary.total === 1 ? tr("Eén ding sinds je keek", "One thing since you looked") : tr(`${inbox.summary.total} dingen sinds je keek`, `${inbox.summary.total} things since you looked`)}</strong>
        {#if inbox.summary.needsYou}<span class="faint">{inbox.summary.needsYou === 1 ? tr("Eén daarvan wacht op jou.", "One of them is waiting on you.") : tr(`${inbox.summary.needsYou} daarvan wachten op jou.`, `${inbox.summary.needsYou} of them are waiting on you.`)}</span>{/if}
        <ul class="digest">
          {#each inbox.summary.sources as row (row.source)}
            <li><span class="meta">{tr(...sources[row.source].label)} · {row.count}</span><span class="detail">{row.latest}</span></li>
          {/each}
        </ul>
      {/if}
      <button class="small primary-soft" onclick={done}>{tr("Gezien", "Mark as seen")}</button>
    </div>
  {:else if view === "history"}
    <div class="panel" in:fade={{ duration: 200 }}>
      {#if inbox.history.length === 0}
        <span class="faint">{tr("Nog niets om terug te kijken.", "Nothing to look back on yet.")}</span>
      {:else}
        <ul class="digest">
          {#each inbox.history.slice(0, 40) as entry (entry.id)}
            <li><span class="meta">{tr(...sources[entry.source].label)} · {relativeTime(entry.at)}</span><span class="detail">{entry.title}</span></li>
          {/each}
        </ul>
      {/if}
    </div>
  {:else if inbox.loading}
    <div class="skeleton" aria-busy="true" aria-label={tr("Laden", "Loading")}>
      {#each [0, 1, 2] as i (i)}<div class="ghost-row" style="animation-delay: {i * 120}ms"><span class="chip"></span><span class="bars"><i></i><i></i></span></div>{/each}
    </div>
  {:else if shown.length === 0}
    <div class="empty" in:fade={{ duration: 300 }}>
      <span class="calm" aria-hidden="true"><Icon name="check" size={22} /></span>
      <strong>{tr("Je bent helemaal bij.", "You're all caught up.")}</strong>
      <span class="faint">{tr("Niets belangrijks is je ontgaan.", "Nothing important slipped past you.")}</span>
    </div>
  {:else}
    <ul>
      {#each shown as item, index (item.id)}
        {@const source = sources[item.source]}
        <li class="item {item.type}" animate:flip={{ duration: 260, easing: cubicOut }} in:fly={{ y: 8, duration: 320, delay: Math.min(index, 5) * 45, easing: cubicOut }} out:slide={{ duration: 220 }}>
          <button class="main" onclick={() => run(item, item.actions[0]?.id ?? "")} disabled={busy === item.id} title={item.actions[0]?.label}>
            <span class="chip" title={tr(...source.label)}><Icon name={source.icon} size={16} /></span>
            <span class="text">
              <span class="meta">{tr(...source.label)}{#if time(item)}<span class="sep">·</span>{time(item)}{/if}</span>
              <span class="title">{item.title}</span>
              {#if item.detail}<span class="detail">{item.detail}</span>{/if}
            </span>
          </button>
          <div class="actions">
            {#each item.actions as action, i (action.id)}
              <button class:primary-soft={i === 0} class="small" disabled={busy === item.id} onclick={() => run(item, action.id)}>{action.label}</button>
            {/each}
            <span class="snooze">
              <button class="small" aria-haspopup="menu" aria-expanded={snoozing === item.id} onclick={() => (snoozing = snoozing === item.id ? null : item.id)}>{tr("Later", "Snooze")}</button>
              {#if snoozing === item.id}
                <span class="menu" role="menu" transition:fade={{ duration: 120 }}>
                  {#each snoozeChoices as [choice, label] (choice)}<button role="menuitem" class="small" onclick={() => snooze(item, choice)}>{tr(...label)}</button>{/each}
                </span>
              {/if}
            </span>
            <button class="ghost icon" onclick={() => inbox.dismiss(item.id)} title={tr("Wegleggen", "Dismiss")} aria-label={tr("Wegleggen", "Dismiss")}><Icon name="x" size={14} /></button>
          </div>
        </li>
      {/each}
    </ul>
    {#if more}
      <button class="ghost more" onclick={() => (expanded = !expanded)} aria-expanded={expanded}>
        {expanded ? tr("Minder tonen", "Show less") : more === 1 ? tr("Nog één rustiger bericht", "One quieter update") : tr(`Nog ${more} rustiger berichten`, `${more} quieter updates`)}
      </button>
    {/if}
  {/if}
  {#if view === "inbox" && (inbox.held.length || inbox.snoozedItems.length)}
    <p class="foot faint">
      {#if inbox.held.length}{inbox.held.length === 1 ? tr("Eén bericht wacht door je focus.", "One item is held back by your focus.") : tr(`${inbox.held.length} berichten wachten door je focus.`, `${inbox.held.length} items are held back by your focus.`)}{/if}
      {#if inbox.snoozedItems.length}{inbox.snoozedItems.length === 1 ? tr("Eén uitgesteld.", "One snoozed.") : tr(`${inbox.snoozedItems.length} uitgesteld.`, `${inbox.snoozedItems.length} snoozed.`)}{/if}
    </p>
  {/if}
</div>

<style>
  .card {
    position: relative; border-radius: var(--radius-panel); padding: 22px 10px 12px;
    background: linear-gradient(180deg, color-mix(in srgb, var(--smoke) 82%, transparent), color-mix(in srgb, var(--graphite) 92%, transparent));
    border: 1px solid var(--line); box-shadow: 0 1px 0 #ffffff08 inset, 0 24px 60px -32px #000a;
    backdrop-filter: blur(18px);
  }
  .head { display: flex; align-items: center; padding: 0 14px 10px; min-height: 28px; }
  .eyebrow { font-size: 11px; font-weight: 650; letter-spacing: 1.4px; text-transform: uppercase; color: var(--text3); }
  .tab { font-size: 11px; padding: 3px 8px; margin-left: 4px; color: var(--text3); }
  .tab.first { margin-left: auto; }
  .tab.on { color: var(--paper); background: color-mix(in srgb, var(--paper) 8%, transparent); }
  .focus { display: flex; flex-wrap: wrap; gap: 4px; padding: 0 14px 8px; }
  .chipbtn { font-size: 11.5px; padding: 3px 10px; border-radius: 999px; color: var(--text3); }
  .chipbtn.on { color: var(--paper); background: color-mix(in srgb, var(--paper) 9%, transparent); }
  .panel { display: flex; flex-direction: column; gap: 8px; padding: 8px 14px 14px; align-items: flex-start; }
  .digest { gap: 10px; width: 100%; }
  .digest li { display: flex; flex-direction: column; gap: 2px; }
  .foot { margin: 6px 14px 4px; font-size: 12px; }
  .snooze { position: relative; }
  .menu { position: absolute; right: 0; top: 100%; z-index: 5; display: flex; flex-direction: column; gap: 2px; padding: 4px; margin-top: 4px; border-radius: var(--radius); background: var(--smoke); border: 1px solid var(--line); box-shadow: 0 12px 30px -12px #000a; }
  .menu .small { text-align: left; border-color: transparent; }
  .refresh { margin-left: 4px; font-size: 11px; padding: 3px 8px; opacity: 0; transition: opacity 160ms ease; }
  .card:hover .refresh, .refresh:focus-visible { opacity: 1; }
  ul { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 2px; }
  .item { position: relative; display: flex; align-items: center; gap: 8px; border-radius: var(--radius); padding-right: 10px; transition: background 180ms ease; }
  .item:hover, .item:focus-within { background: color-mix(in srgb, var(--row-hover) 70%, transparent); }
  .main { flex: 1; min-width: 0; display: flex; gap: 14px; align-items: flex-start; text-align: left; background: none; border: 0; padding: 13px 14px; border-radius: var(--radius); }
  .main:hover:not(:disabled) { background: none; }
  .chip { flex: none; width: 34px; height: 34px; border-radius: 11px; display: grid; place-items: center; color: var(--text2); background: color-mix(in srgb, var(--paper) 6%, transparent); }
  .action_required .chip { color: var(--amber); background: color-mix(in srgb, var(--amber) 11%, transparent); }
  .missed .chip { color: var(--violet); background: color-mix(in srgb, var(--violet) 12%, transparent); }
  .reminder .chip { color: var(--mint); background: color-mix(in srgb, var(--mint) 10%, transparent); }
  .text { min-width: 0; display: flex; flex-direction: column; gap: 3px; }
  .meta { font-size: 11px; color: var(--text3); }
  .sep { margin: 0 6px; }
  .title { font-size: 14px; font-weight: 550; color: var(--paper); overflow: hidden; text-overflow: ellipsis; display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; }
  .detail { font-size: 12.5px; color: var(--text2); line-height: 1.4; overflow: hidden; text-overflow: ellipsis; display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; }
  .actions { display: flex; gap: 6px; align-items: center; flex: none; opacity: 0; transform: translateX(4px); transition: opacity 180ms ease, transform 180ms ease; }
  .item:hover .actions, .item:focus-within .actions { opacity: 1; transform: none; }
  .small { font-size: 12px; padding: 5px 11px; border-radius: 999px; background: transparent; border-color: var(--line2); color: var(--text2); white-space: nowrap; }
  .small:hover:not(:disabled) { color: var(--paper); }
  .primary-soft { color: var(--paper); background: color-mix(in srgb, var(--paper) 8%, transparent); border-color: transparent; }
  .icon { width: 28px; height: 28px; padding: 0; display: grid; place-items: center; border-radius: 999px; }
  .more { margin: 6px 14px 4px; font-size: 12px; padding: 6px 10px; }
  .empty { display: flex; flex-direction: column; align-items: center; text-align: center; gap: 6px; padding: 36px 16px 40px; }
  .empty strong { font-size: 16px; font-weight: 600; margin-top: 10px; }
  .calm {
    width: 54px; height: 54px; border-radius: 50%; display: grid; place-items: center; color: var(--mint);
    background: radial-gradient(circle, color-mix(in srgb, var(--mint) 18%, transparent), color-mix(in srgb, var(--mint) 4%, transparent) 70%);
    box-shadow: 0 0 40px -6px color-mix(in srgb, var(--mint) 35%, transparent);
    animation: settle 900ms cubic-bezier(.2, .8, .2, 1) both;
  }
  @keyframes settle { from { transform: scale(.8); opacity: 0; } to { transform: none; opacity: 1; } }
  .skeleton { display: flex; flex-direction: column; gap: 4px; padding: 0 0 6px; }
  .ghost-row { display: flex; gap: 14px; align-items: center; padding: 13px 14px; animation: shimmer 1.6s ease-in-out infinite; }
  .ghost-row .chip { background: color-mix(in srgb, var(--paper) 6%, transparent); }
  .bars { flex: 1; display: flex; flex-direction: column; gap: 7px; }
  .bars i { display: block; height: 9px; border-radius: 5px; background: color-mix(in srgb, var(--paper) 6%, transparent); width: 70%; }
  .bars i + i { width: 42%; }
  @keyframes shimmer { 50% { opacity: .45; } }
  .compact.card { padding: 14px 6px 8px; }
  .compact .head { padding: 0 12px 4px; }
  .compact .main { padding: 10px 12px; gap: 12px; }
  .compact .chip { width: 30px; height: 30px; border-radius: 10px; }
  .compact .title { font-size: 13px; }
  .compact .detail { font-size: 12px; -webkit-line-clamp: 1; line-clamp: 1; }
  .compact .empty { padding: 20px 12px 24px; }
  .compact .calm { width: 44px; height: 44px; }
  .compact .empty strong { font-size: 14px; margin-top: 6px; }
  /* Touch and narrow layouts have no room or no hover: the actions stay in view, under the text. */
  @media (hover: none) {
    .item { flex-wrap: wrap; padding-right: 0; }
    .actions { opacity: 1; transform: none; padding: 0 14px 12px 62px; flex-wrap: wrap; }
    .main { flex-basis: 100%; padding-bottom: 8px; }
    .refresh { opacity: 1; }
  }
  @container (max-width: 440px) {
    .item { flex-wrap: wrap; padding-right: 0; }
    .actions { opacity: 1; transform: none; padding: 0 14px 12px 62px; flex-wrap: wrap; }
    .main { flex-basis: 100%; padding-bottom: 8px; }
    .refresh { opacity: 1; }
  }
</style>
