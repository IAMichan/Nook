<script lang="ts">
  // Settings: the only place for configuration, laid out as on the Mac (`SettingsSidebar`, `SettingsSection`): a sidebar
  // with a search on top (Ctrl+F or /) and the pages in five groups, each a line icon and a name; over the page a bar
  // with where you are (Settings › group › page), the page's name, and for a page with several subjects the tab bar
  // between them (`SettingsPartTabs`). The layout is `lib/settings-pages.ts`; what each subject shows is in `views`.
  import { tick, type Component } from "svelte";
  import { events } from "../lib/api";
  import { nook } from "../lib/state.svelte";
  import { tr } from "../lib/i18n.svelte";
  import { matchesSearch } from "../lib/shell-routes";
  import {
    groupTitle, pageTitle, sectionTitle, sectionTrail, settingsGroup, settingsGroups, settingsHost, settingsPages, settingsParts,
    settingsSection, settingsSections, type SettingsSectionId,
  } from "../lib/settings-pages";
  import Icon from "../components/Icon.svelte";
  import "./settings/settings.css";
  import SettingsPartTabs from "./settings/SettingsPartTabs.svelte";
  import Overview from "./settings/Overview.svelte";
  import General from "./settings/General.svelte";
  import Brain from "./settings/Brain.svelte";
  import Memory from "./settings/Memory.svelte";
  import Privacy from "./settings/Privacy.svelte";
  import Accounts from "./settings/Accounts.svelte";
  import Assistant from "./settings/Assistant.svelte";
  import Voice from "./settings/Voice.svelte";
  import About from "./settings/About.svelte";
  import Companion from "./settings/Companion.svelte";
  import AgentsSettings from "./settings/Agents.svelte";
  import AgentsUsage from "./settings/AgentsUsage.svelte";
  import AgentsWorkspace from "./settings/AgentsWorkspace.svelte";
  import AgentsAutomation from "./settings/AgentsAutomation.svelte";
  import AutocompleteSettings from "./settings/Autocomplete.svelte";
  import GamesSettings from "./settings/Games.svelte";
  import Appearance from "./settings/Appearance.svelte";
  import Shortcuts from "./settings/Shortcuts.svelte";
  import Instructions from "./settings/Instructions.svelte";
  import Archive from "./settings/Archive.svelte";
  import Maintenance from "./settings/Maintenance.svelte";

  type IconName = "home" | "settings" | "voice" | "gamepad" | "brain" | "sparkle" | "memory" | "pencil" | "terminal" | "link" | "phone" | "hand" | "note" | "palette" | "keyboard" | "message" | "archive" | "wrench" | "bell" | "tasks" | "calendar" | "chat";

  // What each subject shows: a page component, with the part of it this subject is.
  interface Subject { component: Component<any>; props?: Record<string, unknown>; when?: () => boolean }
  const caps = () => nook.info?.capabilities;
  const desktop = () => !!caps()?.desktop;
  const localAgents = () => !!caps()?.localAgents;
  const subjects: Record<SettingsSectionId, Subject> = {
    start: { component: Overview },
    general: { component: General },
    notch: { component: Voice, props: { part: "quiet" }, when: desktop },
    appearance: { component: Appearance },
    notifications: { component: Voice, props: { part: "notices" }, when: desktop },
    sound: { component: Voice, props: { part: "sound" } },
    shortcuts: { component: Shortcuts },
    games: { component: GamesSettings },
    brain: { component: Brain },
    assistant: { component: Assistant },
    memory: { component: Memory },
    instructions: { component: Instructions },
    autocomplete: { component: AutocompleteSettings, props: { part: "general" }, when: desktop },
    autocompleteApps: { component: AutocompleteSettings, props: { part: "apps" }, when: desktop },
    autocompleteStyle: { component: AutocompleteSettings, props: { part: "style" }, when: desktop },
    autocompletePlayground: { component: AutocompleteSettings, props: { part: "playground" }, when: desktop },
    autocompleteStats: { component: AutocompleteSettings, props: { part: "stats" }, when: desktop },
    dictation: { component: Voice, props: { part: "dictation" }, when: () => !!(caps()?.microphone || caps()?.flow) },
    agents: { component: AgentsSettings },
    usage: { component: AgentsUsage, when: localAgents },
    sessions: { component: AgentsWorkspace, when: localAgents },
    archive: { component: Archive },
    automation: { component: AgentsAutomation, when: localAgents },
    chats: { component: Accounts, props: { part: "chats" } },
    connections: { component: Accounts, props: { part: "services" } },
    iphone: { component: Companion, when: desktop },
    privacy: { component: Privacy },
    maintenance: { component: Maintenance },
    about: { component: About },
  };
  const icons: Partial<Record<SettingsSectionId, IconName>> = {
    start: "home", general: "settings", appearance: "palette", notifications: "bell", shortcuts: "keyboard", games: "gamepad",
    brain: "brain", assistant: "sparkle", autocomplete: "pencil",
    agents: "terminal", sessions: "tasks", automation: "calendar",
    chats: "chat", connections: "link", iphone: "phone", privacy: "hand", maintenance: "wrench",
  };

  const shown = (id: SettingsSectionId) => subjects[id].when?.() ?? true;
  /** The subjects of a page this platform shows; a page with none is left out of the sidebar. */
  const visibleParts = (id: SettingsSectionId) => settingsParts(id).filter(shown);

  const stored = () => {
    try { return localStorage.getItem("settings.section"); } catch { return null; }
  };
  let section = $state<SettingsSectionId>(settingsSection(stored()));
  $effect(() => {
    try { localStorage.setItem("settings.section", section); } catch { /* remembering the page is a convenience */ }
  });
  // A button elsewhere (the chat, the welcome, a notice) picks a subject through localStorage and a navigate event.
  $effect(() => {
    const un = events.onNavigate((r) => (section = settingsSection(r.startsWith("settings:") ? r.slice(9) : stored() ?? section)));
    return () => {
      un.then((f) => f());
    };
  });

  /** The subject on screen: the chosen one, else the first its page shows here, else the Overview. */
  const current = $derived(shown(section) ? section : (visibleParts(section)[0] ?? "start"));
  const host = $derived(settingsHost(current));
  const parts = $derived(visibleParts(current));
  const Current = $derived(subjects[current].component);

  // Search: the subjects whose name, page or group has every word typed; ↑ and ↓ move, Return opens.
  let query = $state("");
  let active = $state(0);
  let searchField = $state<HTMLInputElement | null>(null);
  let pane = $state<HTMLDivElement | null>(null);
  const searching = $derived(query.trim().length > 0);
  const hits = $derived(settingsSections.filter((id) => shown(id) &&
    matchesSearch(query, sectionTitle(id), pageTitle(settingsHost(id)), groupTitle(settingsGroup(id)) ?? "")));
  $effect(() => {
    void query;
    active = 0;
  });

  async function open(id: SettingsSectionId) {
    section = id;
    query = "";
    await tick();
    pane?.scrollTo({ top: 0 });
  }

  function searchKeys(e: KeyboardEvent) {
    if (e.key === "ArrowDown" && hits.length) { e.preventDefault(); active = (active + 1) % hits.length; }
    else if (e.key === "ArrowUp" && hits.length) { e.preventDefault(); active = (active - 1 + hits.length) % hits.length; }
    else if (e.key === "Enter" && hits[active]) { e.preventDefault(); open(hits[active]); searchField?.blur(); }
    else if (e.key === "Escape") { e.stopPropagation(); if (query) query = ""; else searchField?.blur(); }
  }

  // "/" where no text is being edited puts the keyboard in the search (Ctrl+F comes from the main window's keys).
  function windowKeys(e: KeyboardEvent) {
    if (e.key !== "/" || e.ctrlKey || e.metaKey || e.altKey || e.defaultPrevented) return;
    const target = e.target instanceof Element ? e.target : null;
    if (target?.closest('input, textarea, select, [contenteditable]:not([contenteditable="false"]), [role="textbox"], .xterm')) return;
    if (document.querySelector('dialog[open], [role="dialog"][aria-modal="true"]')) return;
    e.preventDefault();
    searchField?.focus();
  }
</script>

<svelte:window onkeydown={windowKeys} />

{#if nook.settings}
  <div class="settings">
    <nav aria-label={tr("Instellingen", "Settings")}>
      <div class="settings-search">
        <Icon name="search" size={14} />
        <input bind:this={searchField} bind:value={query} onkeydown={searchKeys} placeholder={tr("Zoek in de instellingen", "Search settings")}
          aria-label={tr("Zoek in de instellingen", "Search settings")} />
        {#if !query}<kbd>/</kbd>{/if}
      </div>
      <div class="pages">
        {#if searching}
          {#if hits.length === 0}
            <p class="none">{tr("Niets gevonden. Probeer een ander woord, zoals ‘brein’, ‘taal’ of ‘privacy’.", "Nothing found. Try another word, like “brain”, “language” or “privacy”.")}</p>
          {/if}
          {#each hits as id, i (id)}
            <button class="navrow" class:on={i === active} aria-current={i === active ? "true" : undefined} onclick={() => open(id)}>
              <span class="mark"><Icon name={icons[settingsHost(id)] ?? "settings"} size={15} /></span>
              <span class="label"><span>{sectionTitle(id)}</span><span class="detail">{[groupTitle(settingsGroup(id)), settingsHost(id) === id ? null : pageTitle(settingsHost(id))].filter(Boolean).join(" › ") || tr("Instellingen", "Settings")}</span></span>
            </button>
          {/each}
        {:else}
          {#each settingsGroups as g (g)}
            {@const rows = settingsPages[g].filter((p) => visibleParts(p.page).length > 0)}
            {#if rows.length}
              <div class="group-rows">
                {#if groupTitle(g)}<div class="heading">{groupTitle(g)}</div>{/if}
                {#each rows as p (p.page)}
                  <button class="navrow" class:on={host === p.page} aria-current={host === p.page ? "page" : undefined} onclick={() => open(visibleParts(p.page)[0])}>
                    <span class="mark"><Icon name={icons[p.page] ?? "settings"} size={15} /></span>
                    <span class="label"><span>{pageTitle(p.page)}</span></span>
                  </button>
                {/each}
              </div>
            {/if}
          {/each}
        {/if}
      </div>
    </nav>
    <div class="main-col">
      <div class="crumbs" aria-label={tr("Waar je bent", "Where you are")}>
        <span class="faint">{tr("Instellingen", "Settings")}</span>
        {#if groupTitle(settingsGroup(current))}
          <span class="chev"><Icon name="chevron-right" size={11} /></span>
          <span class="faint">{groupTitle(settingsGroup(current))}</span>
        {/if}
        <span class="chev"><Icon name="chevron-right" size={11} /></span>
        <span class="here" title={sectionTrail(current)}>{pageTitle(host)}</span>
      </div>
      <div class="pane" bind:this={pane}>
        <div class="page">
          <h2>{pageTitle(host)}</h2>
          {#if parts.length > 1}<SettingsPartTabs {parts} selected={current} onselect={open} />{/if}
          {#key current}
            {#if current === "start"}<Overview onopen={open} />{:else}<Current {...subjects[current].props ?? {}} />{/if}
          {/key}
        </div>
      </div>
    </div>
  </div>
{/if}

<style>
  .settings { display: grid; grid-template-columns: 240px minmax(0, 1fr); height: 100%; min-height: 0; }
  .main-col { display: flex; flex-direction: column; min-width: 0; min-height: 0; }
  @media (max-width: 640px) {
    .settings { grid-template-columns: 1fr; grid-template-rows: auto 1fr; }
  }
</style>
