<script lang="ts" module>
  export interface TabBarTab<T extends string = string> { id: T; icon: string; label: string; count?: number }
</script>

<script lang="ts" generics="T extends string">
  // Tabs along the bottom (the iPhone's tab bar): each with its icon, its name and what waits there.
  import { tr } from "../../lib/i18n.svelte";
  import Ico from "./Ico.svelte";
  let { tabs, tab, onpick }: { tabs: TabBarTab<T>[]; tab: T; onpick: (t: T) => void } = $props();
</script>

<nav class="bar" aria-label={tr("Tabs", "Tabs")}>
  {#each tabs as t (t.id)}
    <button class:on={tab === t.id} aria-current={tab === t.id ? "page" : undefined} onclick={() => onpick(t.id)}>
      <span class="icon">
        <Ico name={t.icon} size={24} stroke={tab === t.id ? 2.2 : 1.8} fill={tab === t.id ? "currentColor" : "none"} />
        {#if (t.count ?? 0) > 0}<span class="badge">{t.count}</span>{/if}
      </span>
      <span class="label">{t.label}</span>
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
