<script lang="ts">
  // The Nook tab of the iPhone app (`ChatListView`): the header, the date and a greeting, what waits on you, works and is
  // unread as tiles, For you (the sessions that need you and the unread chats, a tap away), Nook's recent chats, and a
  // box to ask Nook something. With no chats yet it offers where to start.
  import {
    has, may, needsYouState, relative, unreadChats, writingWaits, Feature,
    type ChatDigest, type ClientView, type CompanionTab, type InboxChatDigest, type SessionDigest,
  } from "../../lib/companion";
  import { locale, tr } from "../../lib/i18n.svelte";
  import { greeting } from "../../lib/companion";
  import PanelHeader from "./ui/PanelHeader.svelte";
  import ConnectionLine from "./ui/ConnectionLine.svelte";
  import Ico from "./ui/Ico.svelte";
  import AgentMark from "./ui/AgentMark.svelte";
  import InboxAvatar from "./ui/InboxAvatar.svelte";
  import StatusPill from "./ui/StatusPill.svelte";
  import PulseDot from "./ui/PulseDot.svelte";
  import NookMark from "./ui/NookMark.svelte";
  import Banner from "./ui/Banner.svelte";
  import SessionComposer from "./ui/SessionComposer.svelte";
  import OfflineStrip from "./ui/OfflineStrip.svelte";

  let { view, inbox, conversations, onorb, ongear, onsession, onchat, onnook, ontab }: {
    view: ClientView;
    inbox: InboxChatDigest[];
    conversations: ChatDigest[];
    onorb: (r: DOMRect) => void;
    ongear: () => void;
    onsession: (id: string) => void;
    onchat: (id: string) => void;
    onnook: (id: string | null, ask?: string) => void;
    ontab: (tab: CompanionTab) => void;
  } = $props();

  let question = $state("");
  let header = $state<HTMLDivElement | null>(null);
  const now = new Date();
  const canChat = $derived(has(view, Feature.chat) && may(view, "nookChat"));
  const chatsAllowed = $derived(has(view, Feature.inbox) && may(view, "chats"));
  const needs = (s: SessionDigest) => s.items.length > 0 || needsYouState(s.attention);
  const waiting = $derived(view.sessions.filter(needs).sort((a, b) => b.updated - a.updated));
  const working = $derived(view.sessions.filter((s) => s.attention === "working" && !needs(s)).length);
  const unread = $derived(chatsAllowed ? inbox.filter((c) => c.unread > 0).sort((a, b) => b.last - a.last) : []);
  const forYou = $derived([...waiting.map((s) => ({ kind: "session" as const, s })), ...unread.map((c) => ({ kind: "chat" as const, c }))].slice(0, 6));
  const showOverview = $derived(view.sessions.length > 0 || conversations.length > 0 || (chatsAllowed && inbox.length > 0));
  const calm = $derived(!waiting.length && !working && !unread.length);
  const suggestions = [tr("Wat staat er vandaag in mijn agenda?", "What’s on my calendar today?"), tr("Vat mijn ongelezen mail samen.", "Summarize my unread mail."), tr("Wat hebben mijn agents vandaag gedaan?", "What did my agents do today?")];

  function ask(text: string) {
    question = "";
    onnook(null, text);
  }
</script>

<div class="tab">
  <div class="scroll">
    <div bind:this={header}>
      <PanelHeader title="Nook" {view} onorb={() => header && onorb((header.querySelector(".orb") as HTMLElement).getBoundingClientRect())} {ongear} />
    </div>
    <div class="top">
      <ConnectionLine {view} />
      {#if showOverview}
        <div class="overview">
          <div class="hello">
            <span class="date">{now.toLocaleDateString(locale(), { weekday: "long", day: "numeric", month: "long" })}</span>
            <h2>{greeting(now.getHours())}</h2>
          </div>
          {#if calm}
            <p class="calm"><span style:color="var(--mint)"><Ico name="circle-check" size={16} /></span>{tr("Alles rustig. Er hoeft nu niets van je.", "All calm. Nothing needs you right now.")}</p>
          {:else}
            <div class="tiles">
              {#if waiting.length}{@render tile(waiting.length, tr("Wacht op jou", "Waiting on you"), "hand", "var(--amber)", true, () => ontab("agents"))}{/if}
              {#if working}{@render tile(working, tr("Aan het werk", "Working"), "circle-dashed", "var(--blue)", false, () => ontab("agents"))}{/if}
              {#if unread.length}{@render tile(unreadChats(inbox), tr("Ongelezen chats", "Unread chats"), "messages-square", "var(--text2)", false, () => ontab("chats"))}{/if}
            </div>
          {/if}
          {#if forYou.length}
            <div class="foryou">
              <span class="label">{tr("Voor jou", "For you")}</span>
              <div class="card">
                {#each forYou as row, i (row.kind === "session" ? row.s.id : row.c.id)}
                  {#if i > 0}<div class="sep"></div>{/if}
                  {#if row.kind === "session"}
                    <button class="fy row-press" onclick={() => onsession(row.s.id)}>
                      <span class="homelogo"><AgentMark agent={row.s.agent} size={18} /></span>
                      <span class="text"><strong>{row.s.title}</strong><span>{row.s.items[0]?.title ?? row.s.folder}</span></span>
                      <StatusPill attention={row.s.items[0]?.kind === "approval" ? "approval" : row.s.items[0]?.kind === "question" ? "input" : row.s.attention} />
                    </button>
                  {:else}
                    <button class="fy row-press" onclick={() => onchat(row.c.id)}>
                      <InboxAvatar id={row.c.id} name={row.c.name} size={32} badge={false} />
                      <span class="text"><strong>{row.c.name}</strong><span>{row.c.preview}</span></span>
                      <span class="unread">{row.c.unread}</span>
                    </button>
                  {/if}
                {/each}
              </div>
            </div>
          {/if}
        </div>
      {/if}
    </div>

    {#if !has(view, Feature.chat)}
      <div class="pad"><Banner icon="circle-arrow-down">{tr("Werk Nook op je Mac bij om vanaf je telefoon met Nook te chatten.", "Update Nook on your Mac to chat with Nook from your phone.")}</Banner></div>
    {:else if canChat}
      {#if !conversations.length}
        <div class="asknook">
          <NookMark size={44} />
          <h2>{tr("Vraag Nook wat je wilt", "Ask Nook anything")}</h2>
          <p>{tr("Je agenda, mail, notities of het web. Plannen en concepten wachten op je goedkeuring op je Mac.", "Your calendar, mail, notes, or the web. Plans and drafts wait for your approval on your Mac.")}</p>
          <div class="grid">
            {#each suggestions as s (s)}
              <button class="suggestion row-press" onclick={() => ask(s)}><span class="spark"><Ico name="sparkles" size={11} /></span><span>{s}</span></button>
            {/each}
          </div>
        </div>
      {:else}
        <h3 class="section">{tr("Recent", "Recent")}</h3>
        <div class="chats">
          {#each conversations as c (c.id)}
            <button class="chatrow row-press" onclick={() => onnook(c.id)}>
              <span class="l1"><strong>{c.title || tr("Nieuwe chat", "New chat")}</strong>
                {#if c.waiting}<StatusPill attention="input" />{:else}<span class="when">{relative(c.updated)}</span>{/if}
              </span>
              {#if c.busy}<span class="l2 busy"><PulseDot size={6} />{tr("Aan het schrijven…", "Writing…")}</span>
              {:else}<span class="l2">{c.preview}</span>{/if}
            </button>
          {/each}
        </div>
      {/if}
    {/if}
  </div>
  {#if canChat}
    <div class="dock">
      <OfflineStrip {view} />
      <SessionComposer bind:value={question} placeholder={tr("Vraag Nook", "Ask Nook")} onsend={ask} canSend={view.phase !== "offline" || writingWaits(view)} />
    </div>
  {/if}
</div>

{#snippet tile(count: number, title: string, icon: string, tint: string, urgent: boolean, onclick: () => void)}
  <button class="tile press" {onclick} style:border-color={urgent ? `color-mix(in srgb, ${tint} 35%, transparent)` : undefined}
    style:background-image="linear-gradient(135deg, color-mix(in srgb, {tint} {urgent ? 14 : 6}%, transparent), transparent 70%)">
    <span class="tilehead"><span style:color={tint}><Ico name={icon} size={13} stroke={2.4} /></span><span class="sp"></span><span class="chev"><Ico name="chevron-right" size={10} stroke={3} /></span></span>
    <span class="count">{count}</span>
    <span class="tiletitle">{title}</span>
  </button>
{/snippet}

<style>
  .tab { flex: 1; min-height: 0; display: flex; flex-direction: column; }
  .scroll { flex: 1; overflow-y: auto; padding-bottom: 24px; }
  .top { display: flex; flex-direction: column; gap: 12px; padding: 0 16px; }
  .pad { padding: 12px 16px; }
  .overview { display: flex; flex-direction: column; gap: 12px; padding-top: 8px; }
  .hello { display: flex; flex-direction: column; gap: 2px; }
  .date { font: var(--pt-label); color: var(--text3); }
  h2 { margin: 0; font: var(--pt-heading); color: var(--paper); }
  .calm { margin: 0; display: flex; align-items: center; gap: 6px; font: var(--pt-body); color: var(--text2); }
  .tiles { display: flex; gap: 8px; }
  .tile { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 4px; padding: 12px; border-radius: 12px; background-color: var(--surface) !important; border: 1px solid var(--line2) !important; text-align: left; }
  .tilehead { display: flex; align-items: center; }
  .sp { flex: 1; }
  .chev { color: var(--text3); display: inline-flex; }
  .count { font: 600 26px/1.1 ui-rounded, var(--font); font-variant-numeric: tabular-nums; color: var(--paper); }
  .tiletitle { font: var(--pt-detail); color: var(--text2); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .foryou { display: flex; flex-direction: column; gap: 6px; }
  .label { font: var(--pt-label); color: var(--text3); }
  .card { background: var(--surface); border: 1px solid var(--line2); border-radius: 12px; padding: 4px 0; }
  .sep { height: 0.5px; background: var(--hairline); margin-left: 52px; }
  .fy { width: 100%; display: flex; align-items: center; gap: 8px; padding: 6px 8px; text-align: left; }
  .homelogo { width: 32px; height: 32px; border-radius: 9px; background: rgba(255, 255, 255, 0.05); display: inline-flex; align-items: center; justify-content: center; flex: none; }
  .text { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 2px; }
  .text strong { font: var(--pt-strong); color: var(--paper); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .text span { font: var(--pt-detail); color: var(--text2); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .unread { min-width: 20px; height: 20px; padding: 0 6px; border-radius: 999px; background: var(--paper); color: var(--ink); font: var(--pt-caption); font-variant-numeric: tabular-nums; display: inline-flex; align-items: center; justify-content: center; box-sizing: border-box; }
  .asknook { display: flex; flex-direction: column; gap: 16px; padding: 24px 16px 0; }
  .asknook p { margin: 0; font: var(--pt-body); color: var(--text2); }
  .asknook h2 { font: var(--pt-display); }
  .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; }
  .suggestion { display: flex; align-items: center; gap: 8px; padding: 8px; min-height: 52px; background: var(--field) !important; border-radius: 12px !important; text-align: left; font: var(--pt-body) !important; color: var(--text-strong) !important; }
  .spark { width: 26px; height: 26px; border-radius: 7.3px; background: rgba(161, 161, 161, 0.12); color: var(--text2); display: inline-flex; align-items: center; justify-content: center; flex: none; }
  .section { margin: 0; padding: 16px 28px 8px; font: var(--pt-label); color: var(--text3); }
  .chats { display: flex; flex-direction: column; gap: 2px; padding: 0 8px; }
  .chatrow { display: flex; flex-direction: column; gap: 4px; padding: 10px 12px; text-align: left; }
  .l1 { display: flex; align-items: center; gap: 8px; }
  .l1 strong { flex: 1; min-width: 0; font: var(--pt-strong); color: var(--paper); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .when { font: var(--pt-detail); color: var(--text3); flex: none; }
  .l2 { font: var(--pt-detail); color: var(--text3); display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
  .l2.busy { display: flex; align-items: center; gap: 6px; color: var(--text2); }
  .dock { padding: 8px 12px; background: linear-gradient(transparent, var(--canvas) 30%); }
</style>
