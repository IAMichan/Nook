<script lang="ts">
  // A menu: sections of rows with an icon, a checkmark on the chosen one and destructive rows in coral, opened near
  // what was clicked or tapped. On the desktop a compact Nook popover that Escape closes; inside the companion
  // (`.phone`) the iPhone's system menu over a dimmed screen.
  import { onBack } from "../../lib/mobile";
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
  $effect(() => {
    const esc = (e: KeyboardEvent) => { if (e.key === "Escape") { e.stopPropagation(); onclose(); } };
    window.addEventListener("keydown", esc, true);
    return () => window.removeEventListener("keydown", esc, true);
  });
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
  /* The desktop: a compact popover. */
  .scrim { position: fixed; inset: 0; z-index: 50; animation: fade 120ms ease-out; }
  .menu { position: fixed; width: 240px; max-height: 70vh; overflow-y: auto; padding: var(--space-4); background: var(--menu); border: 1px solid var(--line2); border-radius: var(--radius-panel); box-shadow: var(--shadow-popover); animation: pop 140ms cubic-bezier(0.2, 0.9, 0.3, 1.1); transform-origin: top left; box-sizing: border-box; }
  .menu.centered { left: 50%; top: 50%; bottom: auto !important; transform: translate(-50%, -50%); animation: fade 120ms ease-out; }
  .reactions { display: flex; justify-content: space-between; padding: var(--space-4); }
  .emoji { width: 30px; height: 30px; padding: 0; border: none; background: none; border-radius: 50%; font-size: 18px; display: inline-flex; align-items: center; justify-content: center; }
  .emoji.mine { background: var(--row-selected) !important; }
  .title { padding: var(--space-6) var(--space-8) var(--space-4); font: var(--pt-caption, var(--text-caption)); color: var(--text3); }
  .gap { height: 1px; margin: var(--space-4) var(--space-6); background: var(--separator); }
  .item { width: 100%; display: flex; align-items: center; gap: var(--space-6); padding: var(--space-4) var(--space-8) var(--space-4) var(--space-4); min-height: 28px; text-align: left; color: var(--paper); background: none; border: none; border-radius: var(--radius-control); box-sizing: border-box; }
  .item:hover:not(.static):not(:disabled) { background: var(--row-hover); }
  .item.destructive { color: var(--coral); }
  .item.static { color: var(--text2); }
  .check { width: 16px; display: inline-flex; justify-content: center; flex: none; }
  .text { flex: 1; min-width: 0; display: flex; flex-direction: column; font: var(--pt-body, var(--text-control)); }
  small { font: var(--pt-detail, var(--text-detail)); color: var(--text3); }

  /* The companion: the iPhone's system menu. */
  :global(.phone) .scrim { background: rgba(0, 0, 0, 0.25); animation-duration: 160ms; }
  :global(.phone) .menu { width: 250px; padding: 0; background: rgba(37, 37, 37, 0.96); backdrop-filter: blur(30px); -webkit-backdrop-filter: blur(30px); border: none; border-radius: 13px; box-shadow: 0 12px 40px rgba(0, 0, 0, 0.55); animation: pop 200ms cubic-bezier(0.2, 0.9, 0.3, 1.1); }
  :global(.phone) .menu.centered { left: 12px; right: 12px; top: auto; bottom: calc(16px + var(--safe-bottom, 0px)) !important; width: auto; transform: none; }
  :global(.phone) .reactions { padding: 6px 8px; }
  :global(.phone) .emoji { width: 36px; height: 36px; font-size: 22px; }
  :global(.phone) .emoji.mine { background: rgba(255, 255, 255, 0.16) !important; }
  :global(.phone) .title { padding: 10px 16px 8px; }
  :global(.phone) .gap { height: 8px; margin: 0; background: rgba(0, 0, 0, 0.3); }
  :global(.phone) .item { gap: 8px; padding: 11px 16px 11px 10px; min-height: 44px; border-radius: 0; border-top: 0.5px solid rgba(255, 255, 255, 0.08) !important; }
  :global(.phone) .gap + .item, :global(.phone) .title + .item, :global(.phone) .menu > .item:first-child { border-top: none !important; }
  :global(.phone) .item:active:not(.static) { background: rgba(255, 255, 255, 0.08) !important; }
  :global(.phone) .check { width: 18px; }
  @keyframes fade { from { opacity: 0; } }
  @keyframes pop { from { opacity: 0; transform: scale(0.9); } }
</style>
