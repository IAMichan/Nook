<script lang="ts">
  // Settings: the only place for configuration, laid out as on the Mac (`SettingsSidebar`): a sidebar with a search on
  // top (Ctrl+F or /) and the pages in their groups, each a line icon and a name; over the page a bar with where you
  // are (Settings › group › page). Every page is its own component in ./settings; a new page is one line in `sections`.
  import { tick, type Component } from "svelte";
  import { events } from "../lib/api";
  import { nook } from "../lib/state.svelte";
  import { tr } from "../lib/i18n.svelte";
  import { matchesSearch, settingsSection, type SettingsSectionId } from "../lib/shell-routes";
  import Icon from "../components/Icon.svelte";
  import "./settings/settings.css";
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
  import AutocompleteSettings from "./settings/Autocomplete.svelte";
  import GamesSettings from "./settings/Games.svelte";
  import Appearance from "./settings/Appearance.svelte";
  import Shortcuts from "./settings/Shortcuts.svelte";
  import Instructions from "./settings/Instructions.svelte";
  import Archive from "./settings/Archive.svelte";
  import Maintenance from "./settings/Maintenance.svelte";

  type IconName = "home" | "settings" | "voice" | "gamepad" | "brain" | "sparkle" | "memory" | "pencil" | "terminal" | "link" | "phone" | "hand" | "note" | "palette" | "keyboard" | "message" | "archive" | "wrench";
  type GroupId = "nook" | "intelligence" | "typing" | "agents" | "connect" | "privacy" | "system";

  interface Section {
    id: SettingsSectionId;
    group: GroupId;
    icon: IconName;
    title: () => string;
    component: Component;
    /// Only shown where this platform can do it.
    when?: () => boolean;
  }

  const desktop = () => !!nook.info?.capabilities.desktop;

  // The groups of the Mac's sidebar; the first and the last stand on their own, without a heading.
  const groups: { id: GroupId; title: () => string | null }[] = [
    { id: "nook", title: () => null },
    { id: "intelligence", title: () => tr("Intelligentie", "Intelligence") },
    { id: "typing", title: () => tr("Typen", "Typing") },
    { id: "agents", title: () => tr("Agents", "Agents") },
    { id: "connect", title: () => tr("Koppelingen", "Connections") },
    { id: "privacy", title: () => tr("Privacy", "Privacy") },
    { id: "system", title: () => null },
  ];

  const sections: Section[] = [
    { id: "overview", group: "nook", icon: "home", title: () => tr("Overzicht", "Overview"), component: Overview },
    { id: "general", group: "nook", icon: "settings", title: () => tr("Algemeen", "General"), component: General },
    { id: "appearance", group: "nook", icon: "palette", title: () => tr("Weergave", "Appearance"), component: Appearance },
    { id: "voice", group: "nook", icon: "voice", title: () => tr("Stem en geluid", "Voice & sound"), component: Voice },
    { id: "games", group: "nook", icon: "gamepad", title: () => "Gamer Mode", component: GamesSettings },
    { id: "shortcuts", group: "nook", icon: "keyboard", title: () => tr("Sneltoetsen", "Shortcuts"), component: Shortcuts },
    { id: "brain", group: "intelligence", icon: "brain", title: () => tr("Brein", "Brain"), component: Brain },
    { id: "assistant", group: "intelligence", icon: "sparkle", title: () => tr("Assistent", "Assistant"), component: Assistant },
    { id: "memory", group: "intelligence", icon: "memory", title: () => tr("Geheugen", "Memory"), component: Memory },
    { id: "instructions", group: "intelligence", icon: "message", title: () => tr("Instructies", "Instructions"), component: Instructions },
    { id: "autocomplete", group: "typing", icon: "pencil", title: () => tr("Aanvullen", "Autocomplete"), component: AutocompleteSettings, when: desktop },
    { id: "agents", group: "agents", icon: "terminal", title: () => "Coding agents", component: AgentsSettings },
    { id: "archive", group: "agents", icon: "archive", title: () => tr("Archief", "Archive"), component: Archive },
    { id: "accounts", group: "connect", icon: "link", title: () => tr("Accounts & koppelingen", "Accounts & connections"), component: Accounts },
    { id: "companion", group: "connect", icon: "phone", title: () => "Companion", component: Companion, when: desktop },
    { id: "privacy", group: "privacy", icon: "hand", title: () => tr("Privacy & beveiliging", "Privacy & security"), component: Privacy },
    { id: "maintenance", group: "system", icon: "wrench", title: () => tr("Onderhoud", "Maintenance"), component: Maintenance },
    { id: "about", group: "system", icon: "note", title: () => tr("Over Nook", "About Nook"), component: About },
  ];

  const stored = () => {
    try { return localStorage.getItem("settings.section"); } catch { return null; }
  };
  let section = $state<SettingsSectionId>(settingsSection(stored()));
  $effect(() => {
    try { localStorage.setItem("settings.section", section); } catch { /* remembering the page is a convenience */ }
  });
  // A button elsewhere (the chat, the welcome, a notice) picks a page through localStorage and a navigate event.
  $effect(() => {
    const un = events.onNavigate(() => (section = settingsSection(stored() ?? section)));
    return () => {
      un.then((f) => f());
    };
  });

  const visible = $derived(sections.filter((s) => !s.when || s.when()));
  const current = $derived(visible.find((s) => s.id === section) ?? visible[0]);
  const Current = $derived(current.component);
  const groupTitle = (id: GroupId) => groups.find((g) => g.id === id)?.title() ?? null;

  // Search: the pages whose name (or group) has every word typed; ↑ and ↓ move, Return opens.
  let query = $state("");
  let active = $state(0);
  let searchField = $state<HTMLInputElement | null>(null);
  let pane = $state<HTMLDivElement | null>(null);
  const searching = $derived(query.trim().length > 0);
  const hits = $derived(visible.filter((s) => matchesSearch(query, s.title(), groupTitle(s.group) ?? "")));
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
    else if (e.key === "Enter" && hits[active]) { e.preventDefault(); open(hits[active].id); searchField?.blur(); }
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
          {#each hits as s, i (s.id)}
            <button class="navrow" class:on={i === active} aria-current={i === active ? "true" : undefined} onclick={() => open(s.id)}>
              <span class="mark"><Icon name={s.icon} size={15} /></span>
              <span class="label"><span>{s.title()}</span><span class="detail">{groupTitle(s.group) ?? tr("Instellingen", "Settings")}</span></span>
            </button>
          {/each}
        {:else}
          {#each groups as g (g.id)}
            {@const rows = visible.filter((s) => s.group === g.id)}
            {#if rows.length}
              <div class="group-rows">
                {#if g.title()}<div class="heading">{g.title()}</div>{/if}
                {#each rows as s (s.id)}
                  <button class="navrow" class:on={section === s.id} aria-current={section === s.id ? "page" : undefined} onclick={() => open(s.id)}>
                    <span class="mark"><Icon name={s.icon} size={15} /></span>
                    <span class="label"><span>{s.title()}</span></span>
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
        {#if groupTitle(current.group)}
          <span class="chev"><Icon name="chevron-right" size={11} /></span>
          <span class="faint">{groupTitle(current.group)}</span>
        {/if}
        <span class="chev"><Icon name="chevron-right" size={11} /></span>
        <span class="here">{current.title()}</span>
      </div>
      <div class="pane" bind:this={pane}>
        <div class="page">
          {#if current.id === "overview"}<Overview onopen={open} />{:else}<Current />{/if}
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
