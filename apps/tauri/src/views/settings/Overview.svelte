<script lang="ts">
  // Overview, the first page of Settings (`startSection` on the Mac): what needs you first, each with the one button
  // that settles it, then one card with a row per main page (its tile, how it stands, and a way there). What works stays
  // quiet; only what still needs you shows an open circle.
  import { nook } from "../../lib/state.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import type { SettingsSectionId } from "../../lib/shell-routes";
  import Ico from "../../components/ui/Ico.svelte";
  import { leaveSettings } from "../../lib/shell-routes";
  import { attention } from "./attention.svelte";
  import { invoke } from "@tauri-apps/api/core";
  import { agentApi } from "../../lib/agents";
  import { automationApi } from "../../lib/workspace/automation";
  import { connectorsApi } from "../../lib/connectors";
  import { companion } from "../../lib/companion";
  import { updater } from "../../lib/updates.svelte";

  let { onopen = () => {} }: { onopen?: (id: SettingsSectionId) => void } = $props();

  // At a glance (`startSection` on the Mac): one row per page that has something to report, in the sidebar's order,
  // each with the page's tile, how it stands, and a circle while it still needs you.
  interface Glance { id: SettingsSectionId; icon: string; title: string; detail: string; todo?: boolean }
  const brainReady = $derived(!!nook.info?.brainReady);
  let linkedAgents = $state<number | null>(null);
  let tasksOn = $state<number | null>(null);
  let chatsLinked = $state<string[] | null>(null);
  let devices = $state<{ enabled: boolean; names: string[] } | null>(null);
  let permissions = $state<{ id: string; granted: boolean }[]>([]);
  $effect(() => {
    attention.refresh();
    if (!nook.info?.capabilities.localAgents) return;
    agentApi.integrations().then((list) => (linkedAgents = list.filter((i) => !i.profileId && (i.state.kind === "installed" || i.state.kind === "outdated")).length)).catch(() => {});
    automationApi.overview().then((o) => (tasksOn = o.tasks.filter((t) => t.enabled).length)).catch(() => {});
    connectorsApi.whatsapp().then((w) => (chatsLinked = w.link?.kind === "connected" ? ["WhatsApp"] : [])).catch(() => (chatsLinked = []));
    companion.info().then((c) => (devices = { enabled: c.enabled, names: c.devices.map((d) => d.name) })).catch(() => {});
    invoke<{ id: string; granted: boolean }[]>("permissions_overview").then((p) => (permissions = Array.isArray(p) ? p : [])).catch(() => {});
  });
  const update = $derived(updater.status);
  const cards = $derived<Glance[]>([
    { id: "brain", icon: "brain", title: tr("Brein", "Brain"), todo: !brainReady,
      detail: brainReady ? (nook.info?.brainLabel ?? tr("Klaar", "Ready")) : tr("Claude, een andere AI of gratis op je computer.", "Claude, another AI, or free on your computer.") },
    ...(nook.info?.capabilities.autocomplete ? [{ id: "autocomplete" as SettingsSectionId, icon: "keyboard", title: tr("Typen", "Typing"), detail: nook.settings?.autocomplete?.enabled ? tr("Aan", "On") : tr("Uit", "Off") }] : []),
    ...(linkedAgents !== null ? [{ id: "agents" as SettingsSectionId, icon: "terminal", title: "Coding agents", todo: linkedAgents === 0, detail: tr("{n} agents gekoppeld", "{n} agents linked", { n: linkedAgents }) }] : []),
    ...(tasksOn !== null ? [{ id: "automation" as SettingsSectionId, icon: "history", title: tr("Automatisering", "Automation"), detail: tasksOn ? tr("{n} taken aan", "{n} tasks on", { n: tasksOn }) : tr("Nog niets ingepland", "Nothing scheduled yet") }] : []),
    { id: "chats", icon: "messages-square", title: tr("Chat-apps", "Chat apps"), todo: !chatsLinked?.length,
      detail: chatsLinked?.length ? tr("{n} gekoppeld: {names}", "{n} linked: {names}", { n: chatsLinked.length, names: chatsLinked.join(", ") }) : tr("Nog geen chat-apps gekoppeld", "No chat apps linked yet") },
    { id: "connections", icon: "user-check", title: tr("Diensten", "Services"), todo: attention.linked === 0,
      detail: tr("{count} bronnen actief. Mail, browser, GitHub, Stripe…", "{count} sources active. Mail, browser, GitHub, Stripe…", { count: attention.linked ?? 0 }) },
    ...(devices ? [{ id: "iphone" as SettingsSectionId, icon: "smartphone", title: tr("Apparaten", "Devices"), detail: !devices.enabled ? tr("Uit", "Off") : devices.names.length ? devices.names.join(", ") : tr("Nog geen telefoon gekoppeld", "No phone paired yet") }] : []),
    ...(permissions.length ? [{ id: "privacy" as SettingsSectionId, icon: "shield-check", title: tr("Toegang", "Access"), todo: permissions.some((p) => !p.granted),
      detail: tr("{n} van {all} machtigingen gegeven", "{n} of {all} permissions granted", { n: permissions.filter((p) => p.granted).length, all: permissions.length }) }] : []),
    { id: "maintenance", icon: "wrench", title: tr("Systeem", "System"),
      detail: update?.phase === "available" ? tr("Update beschikbaar", "Update available") : update?.lastChecked ? tr("Nook is up-to-date", "Nook is up to date") : tr("Nog niet gecontroleerd", "Not checked yet") },
  ]);

  /// Shows the setup steps again: the welcome on the home page, as the Mac's "Open setup" does.
  async function openSetup() {
    await nook.saveSettings({ onboardingDone: false });
    leaveSettings();
  }
</script>

<div class="section-head">
  <h3>{tr("Heeft je aandacht nodig", "Needs your attention")}</h3>
  <button class="link" onclick={openSetup}>{tr("Setup openen", "Open setup")}</button>
</div>
<div class="group">
  {#each attention.items as item (item.id)}
    <div class="row status">
      <span class="state todo"><Ico name="circle" size={18} stroke={1.5} /></span>
      <span class="text"><span>{item.title}</span><span class="faint">{item.detail}</span></span>
      <button class="small" onclick={() => onopen(item.open)}>{item.button}</button>
    </div>
  {:else}
    <div class="row status">
      <span class="state ok"><Ico name="circle-check" size={18} stroke={1.5} /></span>
      <span class="text"><span>{tr("Alles werkt", "Everything works")}</span><span class="faint">{tr("Niets heeft je nu nodig.", "Nothing needs you right now.")}</span></span>
    </div>
  {/each}
</div>

<h3>{tr("In één oogopslag", "At a glance")}</h3>
<div class="group glance">
  {#each cards as card (card.id)}
    <button class="row go-row" onclick={() => onopen(card.id)}>
      <span class="tile"><Ico name={card.icon} size={14} /></span>
      <span class="text">
        <span class="title">{card.title}</span>
        <span class="detail">{card.detail}</span>
      </span>
      {#if card.todo}<span class="state todo"><Ico name="circle" size={18} stroke={1.5} /></span>{/if}
      <span class="go"><Ico name="chevron-right" size={12} /></span>
    </button>
  {/each}
</div>

<style>
  .section-head { display: flex; align-items: baseline; justify-content: space-between; gap: var(--space-12); margin-top: var(--space-32); }
  .section-head h3 { margin: 0; }
  .section-head + .group { margin-top: var(--space-8); }
  .link { border: none; background: none; padding: 0; color: var(--paper); font: var(--text-title); }
  .link:hover:not(:disabled) { background: none; text-decoration: underline; }
  .status { flex-wrap: nowrap !important; justify-content: flex-start !important; }
  .text { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 1px; text-align: left; }
  .status .text > span:first-child { color: var(--paper); }
  .status .text .faint { font: var(--text-detail); line-height: 1.3; color: var(--text2); }
  .state { display: grid; place-items: center; flex: none; }
  .state.ok { color: var(--mint); }
  .state.todo { color: var(--text2); }
  .status .state { margin-right: var(--space-8); }
  /* The circle and the tile keep their size; the text takes the room (the shared row gives it to the first span). */
  .status > .state:first-child, .go-row > .tile:first-child { flex: none; }
  /* The glance card: one row per page, wide as the card, the whole row a button. */
  .glance { padding: 0; overflow: hidden; }
  .go-row { width: 100%; flex-wrap: nowrap; justify-content: flex-start; gap: var(--space-12); padding: var(--space-12) var(--space-16); border: none; border-bottom: 1px solid var(--separator); border-radius: 0; background: none; text-align: left; }
  .go-row:last-child { border-bottom: none; }
  .go-row:hover:not(:disabled) { background: var(--row-hover); }
  .tile { display: grid; place-items: center; width: 26px; height: 26px; flex: none; border-radius: var(--radius-chip); background: var(--smoke); color: var(--text-strong); }
  .title { font: var(--text-body); line-height: 1.3; color: var(--paper); }
  .detail { font: var(--text-detail); line-height: 1.3; color: var(--text2); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .go { display: grid; place-items: center; flex: none; color: var(--text3); }
</style>
