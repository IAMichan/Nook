<script lang="ts">
  // One scroll view for every conversation on the phone (`ConversationScroll` on the iPhone): it opens at the newest
  // message and follows what arrives only while you are at the end. Once you scroll up it holds still however much
  // arrives, and a glass arrow brings you back. What floats over the end ("Working for 12s") never changes the room the
  // conversation has.
  import type { Snippet } from "svelte";
  import { tick } from "svelte";
  import { openUrl } from "@tauri-apps/plugin-opener";
  import { tr } from "../../lib/i18n.svelte";
  import Ico from "./ui/Ico.svelte";

  let { children, floating, version, reserve = 0, background }: {
    children: Snippet;
    floating?: Snippet;
    version: unknown;
    /** Room kept under the content for what floats over it. */
    reserve?: number;
    background?: string;
  } = $props();
  let box = $state<HTMLDivElement | null>(null);
  let atEnd = $state(true);
  let far = $state(false);

  function measure() {
    if (!box) return;
    const gap = box.scrollHeight - box.scrollTop - box.clientHeight;
    atEnd = gap < 32;
    far = gap > 120;
  }
  function toEnd() {
    if (box) box.scrollTop = box.scrollHeight;
    atEnd = true;
    far = false;
  }

  // Something new arrived: follow it only when you were at the end.
  $effect(() => {
    void version;
    const follow = atEnd;
    tick().then(() => follow && toEnd());
  });

  // Links in answers open in the browser, never inside the app.
  function click(e: MouseEvent) {
    const link = (e.target as Element | null)?.closest?.("a[href]") as HTMLAnchorElement | null;
    if (!link) return;
    e.preventDefault();
    if (/^https?:\/\//.test(link.href)) openUrl(link.href).catch(() => {});
  }
</script>

<div class="wrap" style:background>
  <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
  <div class="scroll" bind:this={box} onscroll={measure} onclick={click} style:padding-bottom="{12 + reserve}px">
    <div class="column">{@render children()}</div>
  </div>
  <div class="over">
    {@render floating?.()}
    {#if far}
      <button class="end" onclick={toEnd} aria-label={tr("Naar het einde", "Scroll to end")}><Ico name="arrow-down" size={15} stroke={2.6} /></button>
    {/if}
  </div>
</div>

<style>
  .wrap { flex: 1; min-height: 0; position: relative; display: flex; }
  .scroll { flex: 1; overflow-y: auto; padding: 12px 16px; overscroll-behavior: contain; }
  .column { max-width: 760px; margin: 0 auto; }
  .over { position: absolute; left: 0; right: 0; bottom: 8px; display: flex; justify-content: center; align-items: center; gap: 8px; pointer-events: none; }
  .over > :global(*) { pointer-events: auto; animation: show 240ms ease-out; }
  .end { width: 40px; height: 40px; border-radius: 50%; display: inline-flex; align-items: center; justify-content: center; color: var(--paper) !important; background: rgba(30, 30, 30, 0.72) !important; backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px); border: 1px solid rgba(255, 255, 255, 0.08) !important; }
  @keyframes show { from { opacity: 0; transform: scale(0.96); } }
</style>
