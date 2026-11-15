<script lang="ts">
  // Something that waits for the computer (`WaitingRow`): what it is, "waiting for your Mac", and Don't send on a
  // touch and hold.
  import { tr } from "../../../lib/i18n.svelte";
  import Ico from "./Ico.svelte";
  import Menu from "./Menu.svelte";
  let { icon, title, detail, ondiscard }: { icon: string; title: string; detail: string; ondiscard: () => void } = $props();
  let menu = $state<DOMRect | null>(null);
  let press: ReturnType<typeof setTimeout> | undefined;
  let el = $state<HTMLDivElement | null>(null);
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div bind:this={el} class="waiting" oncontextmenu={(e) => e.preventDefault()}
  onpointerdown={() => (press = setTimeout(() => el && (menu = el.getBoundingClientRect()), 450))} onpointerup={() => clearTimeout(press)} onpointerleave={() => clearTimeout(press)}>
  <span class="icon"><Ico name={icon} size={15} /></span>
  <span class="text"><span class="title">{title}</span><span class="detail"><Ico name="clock" size={11} />{detail}</span></span>
</div>
{#if menu}<Menu anchor={menu} onclose={() => (menu = null)} sections={[[{ label: tr("Niet versturen", "Don’t send"), icon: "trash-2", destructive: true, onselect: ondiscard }]]} />{/if}

<style>
  .waiting { display: flex; align-items: baseline; gap: 8px; padding: 12px; background: var(--field); border-radius: 12px; -webkit-touch-callout: none; user-select: none; }
  .icon { color: var(--text2); position: relative; top: 2px; }
  .text { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 4px; }
  .title { font: var(--pt-body); color: var(--text2); display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
  .detail { display: flex; align-items: center; gap: 4px; font: var(--pt-detail); color: var(--text3); }
</style>
