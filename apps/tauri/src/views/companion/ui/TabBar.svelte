<script lang="ts">
  // The computer's tabs along the bottom (the iPhone's tab bar): Nook, Agents and Chats, each with what waits there.
  import type { CompanionTab } from "../../../lib/companion";
  import { tr } from "../../../lib/i18n.svelte";
  import Ico from "./Ico.svelte";
  let { tabs, tab, counts, onpick }: { tabs: CompanionTab[]; tab: CompanionTab; counts: Record<CompanionTab, number>; onpick: (t: CompanionTab) => void } = $props();
  const icon = (t: CompanionTab) => (t === "home" ? "sparkles" : t === "agents" ? "layers" : "messages-square");
  const label = (t: CompanionTab) => (t === "home" ? "Nook" : t === "agents" ? "Agents" : "Chats");
</script>

<nav class="bar" aria-label={tr("Tabs", "Tabs")}>
  {#each tabs as t (t)}
    <button class:on={tab === t} aria-current={tab === t ? "page" : undefined} onclick={() => onpick(t)}>
      <span class="icon">
        <Ico name={icon(t)} size={24} stroke={tab === t ? 2.2 : 1.8} fill={tab === t ? "currentColor" : "none"} />
        {#if counts[t] > 0}<span class="badge">{counts[t]}</span>{/if}
      </span>
      <span class="label">{label(t)}</span>
    </button>
  {/each}
</nav>

<style>
  .bar { display: flex; justify-content: space-around; background: rgba(0, 0, 0, 0.88); backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px); border-top: 0.5px solid var(--hairline); padding: 6px 8px calc(4px + var(--safe-bottom, 0px)); }
  button { flex: 1; max-width: 120px; display: flex; flex-direction: column; align-items: center; gap: 2px; color: var(--text3); min-height: 49px; justify-content: center; }
  button.on { color: var(--paper); }
  .icon { position: relative; display: inline-flex; }
  .icon :global(svg[fill="currentColor"] path), .icon :global(svg[fill="currentColor"] rect) { fill-opacity: 0.18; }
  .label { font: 500 10px/1.2 var(--font); }
  .badge { position: absolute; top: -4px; left: 16px; min-width: 18px; height: 18px; padding: 0 5px; border-radius: 999px; background: var(--amber); color: var(--ink); font: 600 11px/18px var(--font); text-align: center; box-sizing: border-box; }
</style>
