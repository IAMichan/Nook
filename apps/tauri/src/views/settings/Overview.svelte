<script lang="ts">
  // Overview, the first page of Settings (`startSection` on the Mac): what needs you first, each with the one button
  // that settles it, then one card with a row per main page (its tile, how it stands, and a way there). What works stays
  // quiet; only what still needs you shows a symbol.
  import { nook } from "../../lib/state.svelte";
  import { locale, tr } from "../../lib/i18n.svelte";
  import type { SettingsSectionId } from "../../lib/shell-routes";
  import Ico from "../../components/ui/Ico.svelte";
  import { leaveSettings } from "../../lib/shell-routes";
  import { attention } from "./attention.svelte";
  import { invoke } from "@tauri-apps/api/core";
  import { agentApi, type Integration } from "../../lib/agents";
  import { automationApi, type TaskView } from "../../lib/workspace/automation";
  import { autocomplete, type AutocompleteView } from "../../lib/autocomplete";
  import { connectorsApi, health } from "../../lib/connectors";
  import { companion, type PairedDeviceView } from "../../lib/companion";
  import { updater, startUpdates } from "../../lib/updates.svelte";

  let { onopen = () => {} }: { onopen?: (id: SettingsSectionId) => void } = $props();

  type RowState = "done" | "todo" | "warning" | "error";
  interface AttentionRow {
    id: string;
    title: string;
    detail: string;
    button: string;
    open: SettingsSectionId;
    state: Exclude<RowState, "done">;
  }
  interface Glance {
    id: SettingsSectionId;
    icon: string;
    title: string;
    detail: string;
    state: RowState;
  }

  function formatRelative(iso: string | null | undefined): string | null {
    if (!iso) return null;
    const ms = Date.parse(iso);
    if (!Number.isFinite(ms)) return null;
    const diffSec = Math.round((ms - Date.now()) / 1000);
    const abs = Math.abs(diffSec);
    try {
      const rtf = new Intl.RelativeTimeFormat(locale(), { numeric: "auto" });
      if (abs < 60) return rtf.format(diffSec, "second");
      if (abs < 3600) return rtf.format(Math.round(diffSec / 60), "minute");
      if (abs < 86_400) return rtf.format(Math.round(diffSec / 3600), "hour");
      return rtf.format(Math.round(diffSec / 86_400), "day");
    } catch {
      return new Date(ms).toLocaleTimeString(locale(), { hour: "2-digit", minute: "2-digit" });
    }
  }

  function permissionLabel(id: string): string {
    if (id === "microphone") return tr("Microfoon", "Microphone");
    if (id === "notifications") return tr("Meldingen", "Notifications");
    return id;
  }

  const brainReady = $derived(!!nook.info?.brainReady);
  let integrations = $state<Integration[] | null>(null);
  let tasks = $state<TaskView[] | null>(null);
  let typingView = $state<AutocompleteView | null>(null);
  let chatsLinked = $state<string[] | null>(null);
  let chatBroken = $state(false);
  let brokenServices = $state<{ id: string; title: string; detail: string }[]>([]);
  let devices = $state<{ enabled: boolean; list: PairedDeviceView[] } | null>(null);
  let permissions = $state<{ id: string; granted: boolean }[]>([]);

  $effect(() => {
    attention.refresh();
    startUpdates();
    connectorsApi.overview()
      .then((o) => {
        brokenServices = (o.connectors ?? [])
          .filter((c) => !c.id.startsWith("whatsapp") && ["needsYou", "broken"].includes(health(c)))
          .map((c) => ({
            id: c.id,
            title: c.title || c.id,
            detail: c.status?.detail || c.status?.headline || tr("Opnieuw inloggen nodig", "Needs sign-in again"),
          }));
      })
      .catch(() => {});
    connectorsApi.whatsapp()
      .then((w) => {
        chatsLinked = w.link?.kind === "connected" ? ["WhatsApp"] : [];
        chatBroken = !!w.settings.enabled && !["connected", "connecting", "needsQr"].includes(w.link?.kind ?? "");
      })
      .catch(() => {
        chatsLinked = [];
        chatBroken = false;
      });
    if (nook.info?.capabilities.autocomplete || nook.info?.capabilities.desktop) {
      autocomplete.view().then((v) => (typingView = v)).catch(() => {});
    }
    if (!nook.info?.capabilities.localAgents) return;
    agentApi.integrations().then((list) => (integrations = list.filter((i) => !i.profileId))).catch(() => {});
    automationApi.overview().then((o) => (tasks = o.tasks)).catch(() => {});
    companion.info().then((c) => (devices = { enabled: c.enabled, list: c.devices })).catch(() => {});
    invoke<{ id: string; granted: boolean }[]>("permissions_overview").then((p) => (permissions = Array.isArray(p) ? p : [])).catch(() => {});
  });

  // Live agent counts (installed vs outdated, matching macOS SettingsView+General).
  const installedAgents = $derived(integrations ? integrations.filter((i) => i.state.kind === "installed").length : null);
  const outdatedAgents = $derived(integrations ? integrations.filter((i) => i.state.kind === "outdated") : []);

  // Typing status and words typed today (`TypingGlanceRow` on the Mac).
  const typingEnabled = $derived(!!nook.settings?.autocomplete?.enabled);
  const typingStatus = $derived(typingView?.status ?? attention.typing);
  const typingNeedsAttention = $derived(typingEnabled && (typingStatus?.state === "noModel" || typingStatus?.state === "unsupported"));
  const typingWordsToday = $derived(typingView?.stats?.today?.words ?? 0);

  // Setup checklist progress across the core readiness checks.
  const checklist = $derived.by(() => {
    const steps: boolean[] = [brainReady];
    for (const p of permissions) steps.push(p.granted);
    steps.push((attention.linked ?? 0) >= 1);
    if (installedAgents !== null) steps.push(installedAgents + outdatedAgents.length > 0);
    return { done: steps.filter(Boolean).length, total: steps.length };
  });

  // Full "Needs your attention" list (`attention(problems:)` on the Mac).
  const attentionRows = $derived.by<AttentionRow[]>(() => {
    const rows: AttentionRow[] = attention.items.map((item) => ({ ...item, state: "todo" as const }));
    for (const p of permissions) {
      if (!p.granted) {
        rows.push({
          id: `perm.${p.id}`,
          title: permissionLabel(p.id),
          detail: tr("Nog niet toegestaan", "Not allowed yet"),
          button: tr("Toestaan", "Allow"),
          open: "privacy",
          state: "todo",
        });
      }
    }
    for (const svc of brokenServices) {
      rows.push({
        id: `service.${svc.id}`,
        title: svc.title,
        detail: svc.detail,
        button: tr("Herstel", "Repair"),
        open: "connections",
        state: "warning",
      });
    }
    if (chatBroken || attention.chatProblems > 0) {
      rows.push({
        id: "chat.whatsapp",
        title: "WhatsApp",
        detail: tr("Opnieuw koppelen nodig", "Needs reconnecting"),
        button: tr("Herstel", "Repair"),
        open: "chats",
        state: "warning",
      });
    }
    for (const agent of outdatedAgents) {
      rows.push({
        id: `agent.${agent.target}`,
        title: agent.title,
        detail: tr(
          "Verbonden met een oudere versie: werk bij zodat Nook alles toont (toestemmingen, vragen, samenvatten)",
          "Connected with an older version: update so Nook shows everything (permissions, questions, compacting)",
        ),
        button: tr("Werk bij…", "Update…"),
        open: "agents",
        state: "warning",
      });
    }
    if (typingNeedsAttention) {
      rows.push({
        id: "autocomplete",
        title: tr("Typen", "Typing"),
        detail: tr("Aanvullen mist een toestemming of instelling om te werken.", "Completing needs a permission or a setting to work."),
        button: tr("Bekijk", "View"),
        open: "autocomplete",
        state: "warning",
      });
    }
    return rows;
  });

  // Automation summary (`AutomationGlanceRow` on the Mac).
  const automationGlance = $derived.by<{ detail: string; state: RowState } | null>(() => {
    if (tasks === null) return null;
    const on = tasks.filter((t) => t.enabled);
    if (!on.length) return { detail: tr("Nog niets ingepland", "Nothing scheduled yet"), state: "done" };
    const failed = on.filter((t) => t.lastStatus === "failed").length;
    if (failed > 0) {
      return {
        detail: tr("{n} taken aan · {failed} mislukte de laatste keer", "{n} tasks on · {failed} failed last time", { n: on.length, failed }),
        state: "warning",
      };
    }
    const nextMs = on
      .map((t) => (t.nextRun ? Date.parse(t.nextRun) : NaN))
      .filter((ms) => Number.isFinite(ms))
      .sort((a, b) => a - b)[0];
    const nextLabel = Number.isFinite(nextMs) ? formatRelative(new Date(nextMs).toISOString()) : null;
    if (nextLabel) {
      return { detail: tr("{n} taken aan · volgende {when}", "{n} tasks on · next {when}", { n: on.length, when: nextLabel }), state: "done" };
    }
    return { detail: tr("{n} taken aan", "{n} tasks on", { n: on.length }), state: "done" };
  });

  // Devices summary (`IPhoneGlanceRow` on the Mac).
  const devicesGlance = $derived.by<{ detail: string; state: RowState } | null>(() => {
    if (!devices) return null;
    if (!devices.enabled) return { detail: tr("Uit", "Off"), state: "done" };
    if (!devices.list.length) return { detail: tr("Nog geen telefoon gekoppeld", "No phone paired yet"), state: "todo" };
    const names = devices.list.map((d) => d.name).join(", ");
    if (devices.list.some((d) => d.outdated)) {
      return { detail: `${names} · ${tr("Update nodig", "Needs an update")}`, state: "warning" };
    }
    const latestSeen = devices.list
      .map((d) => (d.lastSeen ? Date.parse(d.lastSeen) : NaN))
      .filter((ms) => Number.isFinite(ms))
      .sort((a, b) => b - a)[0];
    const seenLabel = Number.isFinite(latestSeen) ? formatRelative(new Date(latestSeen).toISOString()) : null;
    if (seenLabel) {
      return { detail: `${names} · ${tr("Laatst gezien {when}", "Last seen {when}", { when: seenLabel })}`, state: "done" };
    }
    return { detail: names, state: "done" };
  });

  // Update summary (`UpdateGlanceRow` on the Mac).
  const update = $derived(updater.status);
  const updateGlance = $derived.by<{ detail: string; state: RowState }>(() => {
    switch (update?.phase) {
      case "available": {
        const version = update.candidate?.version ?? update.manual?.version;
        if (version) return { detail: tr("Nook {version} is beschikbaar", "Nook {version} is available", { version }), state: "warning" };
        return { detail: tr("Update beschikbaar", "Update available"), state: "warning" };
      }
      case "installing":
        return { detail: tr("Nook wordt bijgewerkt", "Updating Nook"), state: "done" };
      case "readyToRestart":
        return { detail: tr("Klaar om te herstarten", "Ready to restart"), state: "warning" };
      case "failed":
        return { detail: tr("De update is niet afgerond", "The update did not finish"), state: "error" };
      case "checking":
        return { detail: tr("Controleren op updates…", "Checking for updates…"), state: "done" };
      case "upToDate":
        return { detail: tr("Nook is up-to-date", "Nook is up to date"), state: "done" };
      default:
        if (update?.problem) return { detail: tr("Kon niet op updates controleren", "Could not check for updates"), state: "warning" };
        if (update?.lastChecked) return { detail: tr("Nook is up-to-date", "Nook is up to date"), state: "done" };
        return { detail: tr("Nog niet gecontroleerd", "Not checked yet"), state: "done" };
    }
  });

  // At a glance (`startSection` on the Mac): one row per page that has something to report, in the sidebar's order.
  const cards = $derived.by<Glance[]>(() => {
    const list: Glance[] = [
      {
        id: "brain",
        icon: "brain",
        title: tr("Brein", "Brain"),
        state: brainReady ? "done" : "todo",
        detail: brainReady
          ? (nook.info?.brainLabel ?? tr("Klaar", "Ready"))
          : tr("Claude, een andere AI of gratis op je computer.", "Claude, another AI, or free on your computer."),
      },
    ];

    if (nook.info?.capabilities.autocomplete) {
      const detail = !typingEnabled
        ? tr("Uit", "Off")
        : typingNeedsAttention
          ? tr("Aanvullen mist een toestemming of instelling om te werken.", "Completing needs a permission or a setting to work.")
          : typingWordsToday > 0
            ? tr("Aan · vandaag {n} woorden voor je getypt", "On · {n} words typed for you today", { n: typingWordsToday })
            : tr("Aan", "On");
      list.push({
        id: "autocomplete",
        icon: "keyboard",
        title: tr("Typen", "Typing"),
        detail,
        state: typingNeedsAttention ? "warning" : "done",
      });
    }

    if (installedAgents !== null) {
      const totalLinked = installedAgents + outdatedAgents.length;
      const detail = outdatedAgents.length > 0
        ? tr("{n} agents gekoppeld · {outdated} verouderd", "{n} agents linked · {outdated} outdated", { n: totalLinked, outdated: outdatedAgents.length })
        : tr("{n} agents gekoppeld", "{n} agents linked", { n: installedAgents });
      list.push({
        id: "agents",
        icon: "terminal",
        title: "Coding agents",
        detail,
        state: outdatedAgents.length > 0 ? "warning" : installedAgents > 0 ? "done" : "todo",
      });
    }

    if (automationGlance) {
      list.push({
        id: "automation",
        icon: "history",
        title: tr("Automatisering", "Automation"),
        detail: automationGlance.detail,
        state: automationGlance.state,
      });
    }

    const brokenChats = chatBroken ? Math.max(1, attention.chatProblems) : attention.chatProblems;
    list.push({
      id: "chats",
      icon: "messages-square",
      title: tr("Chat-apps", "Chat apps"),
      state: brokenChats > 0 ? "warning" : chatsLinked?.length ? "done" : "todo",
      detail: brokenChats > 0
        ? tr("{active} actief · {broken} hebben je nodig", "{active} active · {broken} need you", { active: Math.max(1, chatsLinked?.length ?? 0), broken: brokenChats })
        : chatsLinked?.length
          ? tr("{n} gekoppeld: {names}", "{n} linked: {names}", { n: chatsLinked.length, names: chatsLinked.join(", ") })
          : tr("Nog geen chat-apps gekoppeld", "No chat apps linked yet"),
    });

    const activeServices = attention.linked ?? 0;
    const serviceIssues = Math.max(attention.serviceProblems, brokenServices.length);
    list.push({
      id: "connections",
      icon: "user-check",
      title: tr("Diensten", "Services"),
      state: serviceIssues > 0 ? "warning" : activeServices > 0 ? "done" : "todo",
      detail: serviceIssues > 0
        ? tr("{active} actief · {broken} hebben je nodig", "{active} active · {broken} need you", { active: activeServices, broken: serviceIssues })
        : tr("{count} bronnen actief. Mail, browser, GitHub, Stripe…", "{count} sources active. Mail, browser, GitHub, Stripe…", { count: activeServices }),
    });

    if (devicesGlance) {
      list.push({
        id: "iphone",
        icon: "smartphone",
        title: tr("Apparaten", "Devices"),
        detail: devicesGlance.detail,
        state: devicesGlance.state,
      });
    }

    if (permissions.length) {
      const granted = permissions.filter((p) => p.granted).length;
      list.push({
        id: "privacy",
        icon: "shield-check",
        title: tr("Toegang", "Access"),
        state: granted < permissions.length ? "todo" : "done",
        detail: tr("{n} van {all} machtigingen gegeven", "{n} of {all} permissions granted", { n: granted, all: permissions.length }),
      });
    }

    list.push({
      id: "maintenance",
      icon: "wrench",
      title: tr("Systeem", "System"),
      detail: updateGlance.detail,
      state: updateGlance.state,
    });

    return list;
  });

  /// Shows the setup steps again: the welcome on the home page, as the Mac's "Open setup" does.
  async function openSetup() {
    await nook.saveSettings({ onboardingDone: false });
    leaveSettings();
  }
</script>

{#snippet stateIcon(state: RowState)}
  {#if state === "done"}
    <span class="state ok"><Ico name="circle-check" size={18} stroke={1.5} /></span>
  {:else if state === "warning"}
    <span class="state warn"><Ico name="triangle-alert" size={17} stroke={1.6} /></span>
  {:else if state === "error"}
    <span class="state err"><Ico name="circle-x" size={18} stroke={1.5} /></span>
  {:else}
    <span class="state todo"><Ico name="circle" size={18} stroke={1.5} /></span>
  {/if}
{/snippet}

<div class="section-head">
  <h3>{tr("Heeft je aandacht nodig", "Needs your attention")}</h3>
  <div class="head-actions">
    {#if checklist.done < checklist.total}
      <span class="progress">{tr("{done} van {total} klaar", "{done} of {total} ready", { done: checklist.done, total: checklist.total })}</span>
    {/if}
    <button class="link" onclick={openSetup}>{tr("Setup openen", "Open setup")}</button>
  </div>
</div>
<div class="group">
  {#each attentionRows as item (item.id)}
    <div class="row status">
      {@render stateIcon(item.state)}
      <span class="text"><span>{item.title}</span><span class="faint">{item.detail}</span></span>
      <button class="small" onclick={() => onopen(item.open)}>{item.button}</button>
    </div>
  {:else}
    <div class="row status">
      {@render stateIcon("done")}
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
      {#if card.state !== "done"}{@render stateIcon(card.state)}{/if}
      <span class="go"><Ico name="chevron-right" size={12} /></span>
    </button>
  {/each}
</div>

<style>
  .section-head { display: flex; align-items: baseline; justify-content: space-between; gap: var(--space-12); margin-top: var(--space-32); }
  .section-head h3 { margin: 0; }
  .section-head + .group { margin-top: var(--space-8); }
  .head-actions { display: flex; align-items: baseline; gap: var(--space-12); }
  .progress { font: var(--text-detail); font-variant-numeric: tabular-nums; color: var(--text2); }
  .link { border: none; background: none; padding: 0; color: var(--paper); font: var(--text-title); }
  .link:hover:not(:disabled) { background: none; text-decoration: underline; }
  .status { flex-wrap: nowrap !important; justify-content: flex-start !important; }
  .text { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 1px; text-align: left; }
  .status .text > span:first-child { color: var(--paper); }
  .status .text .faint { font: var(--text-detail); line-height: 1.3; color: var(--text2); }
  .state { display: grid; place-items: center; flex: none; }
  .state.ok { color: var(--mint); }
  .state.todo { color: var(--text2); }
  .state.warn { color: var(--amber); }
  .state.err { color: var(--coral); }
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
