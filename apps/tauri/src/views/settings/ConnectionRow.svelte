<script lang="ts">
  import { tip } from "../../components/ui/tip";
  // One connection in a Settings list (`ConnectionRow` on the Mac): its icon, its name and a version in mono, one line
  // that starts with its state (in amber or coral with a dot only when something needs you), and on the right an
  // optional switch, the "…" menu (Manage/Close first, the destructive items last after a line) and the chevron. A
  // click opens the row in place and shows `expanded`, past the icon. A switched-off row is dimmed.
  import type { Snippet } from "svelte";
  import { tr } from "../../lib/i18n.svelte";
  import DisclosureChevron from "../../components/ui/DisclosureChevron.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import Menu, { type MenuItem } from "../../components/ui/Menu.svelte";
  import Toggle from "../../components/ui/Toggle.svelte";

  let {
    title,
    version = null,
    status,
    attention = null,
    on = null,
    onToggle,
    menu = [],
    danger = [],
    startsOpen = false,
    onopen,
    icon,
    expanded,
  }: {
    title: string;
    version?: string | null;
    /** The line under the name: the state, then what follows it after a "·". */
    status: string;
    /** A state that needs you: the line wears its color with a dot. */
    attention?: "amber" | "coral" | null;
    /** The switch; null for a row without one. */
    on?: boolean | null;
    onToggle?: (on: boolean) => void;
    /** The "…" menu's own items, above the destructive ones. */
    menu?: MenuItem[];
    /** Destructive items, after a line at the bottom of the menu. */
    danger?: MenuItem[];
    startsOpen?: boolean;
    /** Called each time the row opens (to load what it shows). */
    onopen?: () => void;
    icon: Snippet;
    expanded?: Snippet;
  } = $props();

  // svelte-ignore state_referenced_locally
  let open = $state(startsOpen);
  let anchor = $state<DOMRect | null>(null);

  function toggleOpen() {
    if (!expanded) return;
    open = !open;
    if (open) onopen?.();
  }

  function showMenu(e: MouseEvent) {
    e.stopPropagation();
    anchor = (e.currentTarget as HTMLElement).getBoundingClientRect();
  }

  const sections = $derived(
    [
      expanded ? [{ label: open ? tr("Inklappen", "Close") : tr("Beheren", "Manage"), onselect: toggleOpen }] : [],
      menu,
      danger.map((d) => ({ ...d, destructive: true })),
    ].filter((s) => s.length > 0),
  );
</script>

<div class="conn-row">
  <!-- A row that opens is a button; one that does not is a plain row (the role and tabindex follow `expanded`). -->
  <!-- svelte-ignore a11y_no_noninteractive_tabindex -->
  <div
    class="conn-head"
    class:opens={!!expanded}
    class:off={on === false}
    role={expanded ? "button" : undefined}
    tabindex={expanded ? 0 : undefined}
    aria-expanded={expanded ? open : undefined}
    onclick={toggleOpen}
    onkeydown={(e) => expanded && (e.key === "Enter" || e.key === " ") && (e.preventDefault(), toggleOpen())}
  >
    <span class="conn-ico" aria-hidden="true">{@render icon()}</span>
    <span class="conn-main">
      <span class="conn-top">
        <span class="conn-title">{title}</span>
        {#if version}<span class="conn-ver">{version}</span>{/if}
      </span>
      <span class="conn-sub {attention ?? ''}">
        {#if attention}<span class="dot" aria-hidden="true"></span>{/if}
        <span class="conn-sub-text">{status}</span>
      </span>
    </span>
    <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
    <span class="conn-trail" onclick={(e) => e.stopPropagation()}>
      {#if on !== null && onToggle}
        <Toggle {on} onchange={onToggle} label={tr("{title} gebruiken", "Use {title}", { title })} />
      {/if}
      {#if sections.length > 0}
        <button type="button" class="more-btn" use:tip={tr("Meer", "More")} aria-label={tr("Meer", "More")} onclick={showMenu}>
          <Ico name="ellipsis" size={14} />
        </button>
      {:else}
        <span class="more-btn" aria-hidden="true"></span>
      {/if}
      <span class="chev" class:hidden={!expanded} aria-hidden="true"><DisclosureChevron {open} size={10} /></span>
    </span>
  </div>
  {#if open && expanded}
    <div class="conn-detail">{@render expanded()}</div>
  {/if}
</div>

{#if anchor}
  <Menu {anchor} {sections} onclose={() => (anchor = null)} />
{/if}

<style>
  .conn-row { border-bottom: 1px solid var(--separator); }
  .conn-row:last-child { border-bottom: none; }
  .conn-head { display: flex; align-items: center; gap: var(--space-12); padding: var(--row-pad-y) 0; user-select: none; }
  .conn-head.opens { cursor: pointer; }
  .conn-head:focus-visible { outline: 2px solid var(--iris); outline-offset: -2px; border-radius: var(--radius-control); }
  .conn-head.off .conn-ico, .conn-head.off .conn-main { opacity: 0.6; }
  .conn-ico { width: 28px; height: 28px; flex: none; display: grid; place-items: center; color: var(--text2); }
  .conn-main { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: var(--space-2); }
  .conn-top { display: flex; align-items: baseline; gap: var(--space-8); min-width: 0; }
  .conn-title { font: var(--text-emphasis); color: var(--paper); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .conn-ver { font: var(--text-caption); font-family: var(--mono); color: var(--text3); flex: none; }
  .conn-sub { display: flex; align-items: center; gap: var(--space-6); font: var(--text-detail); color: var(--text2); min-width: 0; }
  .conn-sub.amber { color: var(--amber); }
  .conn-sub.coral { color: var(--coral); }
  .conn-sub .dot { width: 6px; height: 6px; border-radius: 50%; background: currentColor; flex: none; }
  .conn-sub-text { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .conn-trail { display: inline-flex; align-items: center; gap: var(--space-8); flex: none; }
  .more-btn { width: 24px; height: 24px; padding: 0; border: none; border-radius: var(--radius-chip); background: transparent; color: var(--text2); display: grid; place-items: center; cursor: pointer; }
  button.more-btn:hover { background: var(--row-hover); color: var(--paper); }
  .chev { width: 12px; display: grid; place-items: center; color: var(--text3); }
  .chev.hidden { visibility: hidden; }
  .conn-detail { display: flex; flex-direction: column; gap: var(--space-12); padding: var(--space-4) 0 var(--space-16) calc(28px + var(--space-12)); }
</style>
