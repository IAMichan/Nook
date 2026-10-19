<script lang="ts">
  // Instellingen: de enige plek voor configuratie. Elke sectie is een eigen component in ./settings;
  // een nieuwe sectie is één regel in `sections`.
  import type { Component } from "svelte";
  import { events } from "../lib/api";
  import { nook } from "../lib/state.svelte";
  import "./settings/settings.css";
  import General from "./settings/General.svelte";
  import Brain from "./settings/Brain.svelte";
  import Memory from "./settings/Memory.svelte";
  import Privacy from "./settings/Privacy.svelte";
  import About from "./settings/About.svelte";

  interface Section {
    id: string;
    title: string;
    component: Component;
    /// Alleen tonen als dit platform het kan.
    when?: () => boolean;
  }

  const sections: Section[] = [
    { id: "general", title: "Algemeen", component: General },
    { id: "brain", title: "Brein", component: Brain },
    { id: "memory", title: "Geheugen", component: Memory },
    { id: "privacy", title: "Privacy & beveiliging", component: Privacy },
    { id: "about", title: "Over Nook", component: About },
  ];

  let section = $state(localStorage.getItem("settings.section") ?? "brain");
  $effect(() => {
    localStorage.setItem("settings.section", section);
  });
  // Een knop elders (chat, welkom) kan een sectie kiezen via localStorage + navigate.
  $effect(() => {
    const un = events.onNavigate(() => (section = localStorage.getItem("settings.section") ?? section));
    return () => {
      un.then((f) => f());
    };
  });
  const visible = $derived(sections.filter((s) => !s.when || s.when()));
  const Current = $derived(visible.find((s) => s.id === section)?.component ?? Brain);
</script>

{#if nook.settings}
  <div class="settings">
    <nav>
      {#each visible as s (s.id)}
        <button class:on={section === s.id} onclick={() => (section = s.id)}>{s.title}</button>
      {/each}
    </nav>
    <div class="pane"><Current /></div>
  </div>
{/if}

<style>
  .settings { display: grid; grid-template-columns: 200px 1fr; height: 100%; }
</style>
