<script lang="ts">
  // A menu as the iPhone's system menus show it: sections of rows with an icon, a checkmark on the chosen one and
  // destructive rows in coral, over a dimmed screen. It opens near what was tapped.
  import { onBack } from "../../../lib/mobile";
  import Ico from "./Ico.svelte";

  export interface MenuItem {
    label: string;
    icon?: string;
    destructive?: boolean;
    checked?: boolean;
    disabled?: boolean;
    detail?: string;
    onselect?: () => void;
  }

  /** A row of emoji above the rows (a message's quick reactions): the ones in `mine` are marked, a tap picks one. */
  export interface MenuReactions { emoji: string[]; mine: string[]; onpick: (emoji: string) => void }

  let { sections, anchor, title, reactions, onclose }: {
    sections: MenuItem[][]; anchor?: DOMRect | null; title?: string; reactions?: MenuReactions; onclose: () => void;
  } = $props();
  $effect(() => onBack(() => (onclose(), true)));
  const below = $derived(!anchor || anchor.bottom < window.innerHeight * 0.55);
  const top = $derived(anchor ? (below ? anchor.bottom + 6 : undefined) : undefined);
  const bottom = $derived(anchor && !below ? window.innerHeight - anchor.top + 6 : undefined);
  const left = $derived(anchor ? Math.min(Math.max(12, anchor.left), window.innerWidth - 262) : undefined);
</script>

<!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
<div class="scrim" onclick={onclose}>
  <div class="menu" role="menu" tabindex="-1" style:top={top !== undefined ? `${top}px` : undefined} style:bottom={bottom !== undefined ? `${bottom}px` : anchor ? undefined : "calc(16px + var(--safe-bottom, 0px))"} style:left={left !== undefined ? `${left}px` : undefined} class:centered={!anchor} onclick={(e) => e.stopPropagation()}>
    {#if title}<div class="title">{title}</div>{/if}
    {#if reactions}
      <div class="reactions">
        {#each reactions.emoji as e (e)}
          <button class="emoji" class:mine={reactions.mine.includes(e)} aria-label={e} aria-pressed={reactions.mine.includes(e)} onclick={() => { reactions.onpick(e); onclose(); }}>{e}</button>
        {/each}
      </div>
    {/if}
    {#each sections.filter((s) => s.length) as section, i (i)}
      {#if i > 0 || title || reactions}<div class="gap"></div>{/if}
      {#each section as item, j (j)}
        {#if item.onselect}
          <button role="menuitem" class="item" class:destructive={item.destructive} disabled={item.disabled} onclick={() => { item.onselect?.(); onclose(); }}>
            <span class="check">{#if item.checked}<Ico name="check" size={14} stroke={2.6} />{/if}</span>
            <span class="text"><span>{item.label}</span>{#if item.detail}<small>{item.detail}</small>{/if}</span>
            {#if item.icon}<Ico name={item.icon} size={17} />{/if}
          </button>
        {:else}
          <div class="item static"><span class="check"></span><span class="text"><span>{item.label}</span>{#if item.detail}<small>{item.detail}</small>{/if}</span>{#if item.icon}<Ico name={item.icon} size={17} />{/if}</div>
        {/if}
      {/each}
    {/each}
  </div>
</div>

<style>
  .scrim { position: fixed; inset: 0; z-index: 50; background: rgba(0, 0, 0, 0.25); animation: fade 160ms ease-out; }
  .menu { position: fixed; width: 250px; max-height: 70vh; overflow-y: auto; background: rgba(37, 37, 37, 0.96); backdrop-filter: blur(30px); -webkit-backdrop-filter: blur(30px); border-radius: 13px; box-shadow: 0 12px 40px rgba(0, 0, 0, 0.55); animation: pop 200ms cubic-bezier(0.2, 0.9, 0.3, 1.1); transform-origin: top left; }
  .menu.centered { left: 12px; right: 12px; width: auto; }
  .reactions { display: flex; justify-content: space-between; padding: 6px 8px; }
  .emoji { width: 36px; height: 36px; border-radius: 50%; font-size: 22px; display: inline-flex; align-items: center; justify-content: center; }
  .emoji.mine { background: rgba(255, 255, 255, 0.16) !important; }
  .title { padding: 10px 16px 8px; font: var(--pt-caption); color: var(--text3); }
  .gap { height: 8px; background: rgba(0, 0, 0, 0.3); }
  .item { width: 100%; display: flex; align-items: center; gap: 8px; padding: 11px 16px 11px 10px; min-height: 44px; text-align: left; color: var(--paper); border-top: 0.5px solid rgba(255, 255, 255, 0.08) !important; box-sizing: border-box; }
  .gap + .item, .title + .item, .menu > .item:first-child { border-top: none !important; }
  .item:active:not(.static) { background: rgba(255, 255, 255, 0.08) !important; }
  .item.destructive { color: var(--coral); }
  .item.static { color: var(--text2); }
  .check { width: 18px; display: inline-flex; justify-content: center; flex: none; }
  .text { flex: 1; min-width: 0; display: flex; flex-direction: column; font: var(--pt-body); }
  small { font: var(--pt-detail); color: var(--text3); }
  @keyframes fade { from { opacity: 0; } }
  @keyframes pop { from { opacity: 0; transform: scale(0.9); } }
</style>
