<script lang="ts">
  // Settings: the only place for configuration, laid out as on the Mac (`SettingsSidebar`, `SettingsSection`): a sidebar
  // with a search on top (Ctrl+F or /) and the pages in five groups, each a line icon and a name; over the page a bar
  // with where you are (Settings › group › page), the page's name, and for a page with several subjects the tab bar
  // between them (`SettingsPartTabs`). The layout is `lib/settings-pages.ts`; what each subject shows is in `views`.
  import { tick, type Component } from "svelte";
  import { leaveSettings } from "../lib/shell-routes";
  import { events } from "../lib/api";
  import { nook } from "../lib/state.svelte";
  import { tr } from "../lib/i18n.svelte";
  import { matchesSearch } from "../lib/shell-routes";
  import {
    groupTitle, pageTitle, sectionIcons, sectionTitle, sectionTrail, settingsGroup, settingsGroups, settingsHost, settingsPages, settingsParts,
    settingsSection, settingsSections, type SettingsSectionId,
  } from "../lib/settings-pages";
  import Ico from "../components/ui/Ico.svelte";
  import CountBadge from "../components/ui/CountBadge.svelte";
  import ConfirmedButton from "../components/ui/ConfirmedButton.svelte";
  import { toast } from "../lib/toast.svelte";
  import { ACCENTS } from "../lib/theme";
  import { LOOK_PRESETS } from "../lib/types";
  import { loadAgentsView, onAgentsView, saveAgentsView } from "../lib/agents-view";
  import { attention } from "./settings/attention.svelte";
  import { lightSetting, settingHits, settingsHighlight } from "../lib/settings-search.svelte";
  import { pageSubtitle, sectionSubtitle, sectionInfo } from "./settings/intro";
  import "./settings/settings.css";
  import SettingsPartTabs from "./settings/SettingsPartTabs.svelte";
  import Overview from "./settings/Overview.svelte";
  import General from "./settings/General.svelte";
  import Notch from "./settings/Notch.svelte";
  import Brain from "./settings/Brain.svelte";
  import Memory from "./settings/Memory.svelte";
  import Privacy from "./settings/Privacy.svelte";
  import Accounts from "./settings/Accounts.svelte";
  import Assistant from "./settings/Assistant.svelte";
  import Voice from "./settings/Voice.svelte";
  import About from "./settings/About.svelte";
  import Companion from "./settings/Companion.svelte";
  import AgentsSettings from "./settings/Agents.svelte";
  import AgentsSkills from "./settings/AgentsSkills.svelte";
  import AgentsUsage from "./settings/AgentsUsage.svelte";
  import AgentsWorkspace from "./settings/AgentsWorkspace.svelte";
  import WorktreesSettings from "./settings/Worktrees.svelte";
  import AgentsAutomation from "./settings/AgentsAutomation.svelte";
  import AutocompleteSettings from "./settings/Autocomplete.svelte";
  import GamesSettings from "./settings/Games.svelte";
  import Appearance from "./settings/Appearance.svelte";
  import Shortcuts from "./settings/Shortcuts.svelte";
  import Instructions from "./settings/Instructions.svelte";
  import Archive from "./settings/Archive.svelte";
  import Maintenance from "./settings/Maintenance.svelte";
  import Projects from "./settings/Projects.svelte";
  import NoticeApps from "./settings/NoticeApps.svelte";
  import PullRequests from "./settings/PullRequests.svelte";


  // What each subject shows: a page component, with the part of it this subject is.
  interface Subject { component: Component<any>; props?: Record<string, unknown>; when?: () => boolean }
  const caps = () => nook.info?.capabilities;
  const desktop = () => !!caps()?.desktop;
  const localAgents = () => !!caps()?.localAgents;
  const subjects: Record<SettingsSectionId, Subject> = {
    start: { component: Overview },
    general: { component: General },
    notch: { component: Notch, when: desktop },
    appearance: { component: Appearance },
    notifications: { component: Voice, props: { part: "notices" }, when: desktop },
    notificationApps: { component: NoticeApps, when: desktop },
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
    skills: { component: AgentsSkills, when: localAgents },
    usage: { component: AgentsUsage, when: localAgents },
    sessions: { component: AgentsWorkspace, props: { part: "sessions" }, when: localAgents },
    worktrees: { component: WorktreesSettings, when: localAgents },
    openIn: { component: AgentsWorkspace, props: { part: "openIn" }, when: localAgents },
    archive: { component: Archive },
    automation: { component: AgentsAutomation, when: localAgents },
    projects: { component: Projects, when: localAgents },
    pullRequests: { component: PullRequests },
    chats: { component: Accounts, props: { part: "chats" } },
    connections: { component: Accounts, props: { part: "services" } },
    iphone: { component: Companion, when: desktop },
    privacy: { component: Privacy, props: { part: "level" } },
    permissions: { component: Privacy, props: { part: "access" } },
    activityLog: { component: Privacy, props: { part: "log" } },
    maintenance: { component: Maintenance },
    about: { component: About },
  };
  const icons = sectionIcons;

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

  // Search (`SettingsSearch`): first the subjects whose name, page or group has every word typed, then every setting
  // whose on-screen name has them; ↑ and ↓ move, Return opens. A setting opens its subject and is scrolled to and lit.
  let query = $state("");
  let active = $state(0);
  let searchField = $state<HTMLInputElement | null>(null);
  let pane = $state<HTMLDivElement | null>(null);
  const searching = $derived(query.trim().length > 0);
  type Hit = { key: string; section: SettingsSectionId; title: string; setting: boolean };
  const hits = $derived<Hit[]>(searching ? [
    ...settingsSections.filter((id) => shown(id) &&
      matchesSearch(query, sectionTitle(id), pageTitle(settingsHost(id)), groupTitle(settingsGroup(id)) ?? ""))
      .map((id) => ({ key: id, section: id, title: sectionTitle(id), setting: false })),
    ...settingHits(query, shown).map((h) => ({ key: `${h.section}:${h.title}`, section: h.section, title: h.title, setting: true })),
  ] : []);
  $effect(() => {
    void query;
    active = 0;
  });

  $effect(() => attention.refresh());

  async function open(id: SettingsSectionId) {
    section = id;
    query = "";
    await tick();
    pane?.scrollTo({ top: 0 });
  }

  /** Opens a search hit; a setting is lit once its page has drawn it (pages load their data first, so look a few times). */
  async function openHit(hit: Hit) {
    if (!hit.setting) return open(hit.section);
    settingsHighlight.title = hit.title;
    await open(hit.section);
    const title = hit.title;
    for (let tries = 0; tries < 10 && settingsHighlight.title === title; tries++) {
      await new Promise((r) => setTimeout(r, 150));
      if (pane && lightSetting(pane, title)) break;
    }
    if (settingsHighlight.title === title) settingsHighlight.title = null;
  }

  function searchKeys(e: KeyboardEvent) {
    if (e.key === "ArrowDown" && hits.length) { e.preventDefault(); active = (active + 1) % hits.length; }
    else if (e.key === "ArrowUp" && hits.length) { e.preventDefault(); active = (active - 1 + hits.length) % hits.length; }
    else if (e.key === "Enter" && hits[active]) { e.preventDefault(); openHit(hits[active]); searchField?.blur(); }
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

  // "Restore defaults" in the bar (`SettingsRestore`), after a confirmation, on the pages whose own settings have a
  // default to go back to, as on the Mac: General and Appearance. It dims once nothing on the page differs any more.
  // Appearance: its look back to how Nook ships; imported themes stay, they are yours, not a default (as on the Mac).
  const appearanceChanged = $derived(!!nook.settings && (nook.settings.theme !== "dark" || nook.settings.accentHex !== ACCENTS[0] || nook.settings.density !== "comfortable"
    || (nook.settings.darkTheme ?? "nook") !== "nook" || (nook.settings.lightTheme ?? "nook") !== "nook" || (nook.settings.diffColors ?? "redGreen") !== "redGreen"
    || Object.keys(nook.settings.colorOverrides?.dark ?? {}).length > 0 || Object.keys(nook.settings.colorOverrides?.light ?? {}).length > 0
    || JSON.stringify(nook.settings.nookLook ?? LOOK_PRESETS[1].look) !== JSON.stringify(LOOK_PRESETS[1].look)));
  // General's own settings (`GeneralListAndConfirmations`): the session list's layout and asking before quitting; the
  // languages are yours, not a default.
  let listView = $state(loadAgentsView());
  $effect(() => onAgentsView((v) => (listView = v)));
  const generalChanged = $derived(listView.projectFolders || !listView.showWorking || nook.settings?.confirmQuit === false);
  async function restoreGeneral() {
    saveAgentsView({ projectFolders: false, showWorking: true });
    await nook.saveSettings({ confirmQuit: true });
    toast.success(tr("Standaardwaarden hersteld", "Defaults restored"));
  }
  const restore = $derived(host === "appearance" ? { changed: appearanceChanged, run: restoreAppearance } : host === "general" ? { changed: generalChanged, run: restoreGeneral } : null);

  async function restoreAppearance() {
    await nook.saveSettings({ theme: "dark", accentHex: ACCENTS[0], density: "comfortable", darkTheme: "nook", lightTheme: "nook", diffColors: "redGreen", colorOverrides: { dark: {}, light: {} }, nookLook: { ...LOOK_PRESETS[1].look } });
    toast.success(tr("Standaardwaarden hersteld", "Defaults restored"));
  }

  /// Back to the page Settings was opened from (`Main.svelte` keeps it).
  function leave() {
    leaveSettings();
  }
</script>

<svelte:window onkeydown={windowKeys} />

{#if nook.settings}
  <div class="settings">
    <nav aria-label={tr("Instellingen", "Settings")}>
      <!-- Settings is a window of its own on the Mac, its sidebar under the traffic lights. Here it takes the whole main
           window, and that top row leads back to where you were (Escape too). -->
      <div class="settings-head" data-tauri-drag-region>
        <button class="settings-back" onclick={leave} title={tr("Terug (Esc)", "Back (Esc)")}><Ico name="chevron-left" size={14} /><span>{tr("Terug", "Back")}</span></button>
      </div>
      <div class="settings-search">
        <Ico name="search" size={13} />
        <input bind:this={searchField} bind:value={query} onkeydown={searchKeys} placeholder={tr("Zoek in alle instellingen", "Search all settings")}
          aria-label={tr("Zoek in alle instellingen", "Search all settings")} />
        {#if query}
          <button class="clear" onclick={() => { query = ""; searchField?.focus(); }} aria-label={tr("Wissen", "Clear")}><Ico name="circle-x" size={14} /></button>
        {:else}<kbd>/</kbd>{/if}
      </div>
      <div class="pages">
        {#if searching}
          {#if hits.length === 0}
            <p class="none">{tr("Niets gevonden. Probeer een ander woord, zoals ‘brein’, ‘taal’ of ‘privacy’.", "Nothing found. Try another word, like “brain”, “language” or “privacy”.")}</p>
          {/if}
          {#each hits as hit, i (hit.key)}
            <button class="navrow" class:on={i === active} aria-current={i === active ? "true" : undefined} onclick={() => openHit(hit)}>
              <span class="mark"><Ico name={icons[hit.section]} size={15} /></span>
              <span class="label"><span>{hit.title}</span><span class="detail">{sectionTrail(hit.section)}</span></span>
            </button>
          {/each}
        {:else}
          {#each settingsGroups as g (g)}
            {@const rows = settingsPages[g].filter((p) => visibleParts(p.page).length > 0)}
            {#if rows.length}
              <div class="group-rows">
                {#if groupTitle(g)}<div class="heading">{groupTitle(g)}</div>{/if}
                {#each rows as p (p.page)}
                  {@const badge = attention.badge(p.page)}
                  <button class="navrow" class:on={host === p.page} aria-current={host === p.page ? "page" : undefined} onclick={() => open(visibleParts(p.page)[0])}>
                    <span class="mark"><Ico name={icons[p.page]} size={15} /></span>
                    <span class="label"><span>{pageTitle(p.page)}</span></span>
                    <CountBadge count={badge} />
                  </button>
                {/each}
              </div>
            {/if}
          {/each}
        {/if}
      </div>
    </nav>
    <div class="main-col">
      <!-- The bar over the page (`SettingsPageBar`): where you are, Settings › page. -->
      <div class="crumbs" aria-label={tr("Waar je bent", "Where you are")} data-tauri-drag-region>
        <span class="faint">{tr("Instellingen", "Settings")}</span>
        <span class="chev"><Ico name="chevron-right" size={10} stroke={2.5} /></span>
        <span class="here" title={sectionTrail(current)}>{pageTitle(host)}</span>
        {#if restore}
          <span class="spacer"></span>
          <ConfirmedButton class="restore" question={tr("De standaardwaarden van {page} herstellen?", "Restore the defaults of {page}?", { page: pageTitle(host) })}
            confirmTitle={tr("Standaardwaarden herstellen", "Restore defaults")} disabled={!restore.changed} onconfirm={restore.run}>
            <Ico name="rotate-ccw" size={12} /><span>{tr("Standaardwaarden herstellen", "Restore defaults")}</span>
          </ConfirmedButton>
        {/if}
      </div>
      <div class="pane" bind:this={pane}>
        <div class="page">
          <!-- The top of every page (`SettingsPageIntro`): its name, one line on what it holds, the tabs of its subjects
               with a line on the one shown, and for a few subjects how they treat your data. -->
          <header class="intro">
            <h2>{pageTitle(host)}</h2>
            <p class="lead">{pageSubtitle(host, parts.length > 1)}</p>
            {#if parts.length > 1}
              <SettingsPartTabs {parts} selected={current} onselect={open} icon={(id) => icons[id]} />
              {#if current !== host}<p class="part-lead">{sectionSubtitle(current)}</p>{/if}
            {/if}
            {#if sectionInfo(current)}<p class="info">{sectionInfo(current)}</p>{/if}
          </header>
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
