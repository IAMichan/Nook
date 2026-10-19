<script lang="ts">
  // De werkruimte (`WorkspaceView` op de Mac): terminals, de browser van Nook, worktrees en gebruik. Sessies zelf
  // staan in de tab Agents; hier staat het gereedschap eromheen.
  import { nook } from "../lib/state.svelte";
  import Browser from "./workspace/Browser.svelte";
  import Terminals from "./workspace/Terminals.svelte";
  import UsagePage from "./workspace/UsagePage.svelte";
  import Worktrees from "./workspace/Worktrees.svelte";

  let { compact = false }: { compact?: boolean } = $props();
  type Page = "terminals" | "browser" | "worktrees" | "usage";
  let page = $state<Page>((localStorage.getItem("ws.page") as Page) || "terminals");

  $effect(() => {
    try {
      localStorage.setItem("ws.page", page);
    } catch {
      // Geen opslag: de keuze geldt alleen nu.
    }
  });

  const desktop = $derived(nook.info?.capabilities.terminals ?? false);
  const pages: [Page, string][] = [["terminals", "Terminals"], ["browser", "Browser"], ["worktrees", "Worktrees"], ["usage", "Gebruik"]];
</script>

{#if !nook.info}
  <div class="empty"><p class="faint">Laden…</p></div>
{:else if !desktop}
  <div class="empty">
    <p>De werkruimte draait op je computer, niet op je telefoon.</p>
    <p class="faint">
      Terminals, de browser van Nook, worktrees en de sessies van coding-agents horen bij je Windows- of Linux-computer
      (of je Mac). Open Nook daar; op de telefoon volg je ze via de companion zodra die gekoppeld is.
    </p>
  </div>
{:else}
  <div class="workspace" class:compact>
    <nav>
      {#each pages as [id, label] (id)}<button class:on={page === id} onclick={() => (page = id)}>{label}</button>{/each}
    </nav>
    <div class="page">
      {#if page === "terminals"}<Terminals />
      {:else if page === "browser"}<Browser />
      {:else if page === "worktrees"}<Worktrees />
      {:else}<UsagePage />{/if}
    </div>
  </div>
{/if}

<style>
  .workspace { display: flex; flex-direction: column; height: 100%; min-height: 0; padding: 10px 14px; gap: 10px; box-sizing: border-box; }
  nav { display: flex; gap: 4px; }
  nav button { background: none; border: none; font-size: 12.5px; padding: 5px 10px; border-radius: 8px; color: var(--text2); }
  nav button.on, nav button:hover { background: var(--smoke); color: var(--paper); }
  .page { flex: 1; min-height: 0; display: flex; flex-direction: column; }
  .empty { padding: 24px; text-align: center; max-width: 520px; margin: 0 auto; }
</style>
