<script lang="ts">
  // One scroll view for every conversation on the phone (a session, a chat with Nook, a chat in your apps), as
  // `ConversationScroll` on the iPhone: it opens at the newest message and follows what arrives only while you are at the
  // end. Once you scroll up it holds still however much arrives, and an arrow brings you back.
  import type { Snippet } from "svelte";
  import { tick } from "svelte";
  import { openUrl } from "@tauri-apps/plugin-opener";
  import { tr } from "../../lib/i18n.svelte";
  import Icon from "../../components/Icon.svelte";

  let { children, version }: { children: Snippet; version: unknown } = $props();
  let box = $state<HTMLDivElement | null>(null);
  let atEnd = $state(true);

  const nearEnd = (el: HTMLDivElement) => el.scrollHeight - el.scrollTop - el.clientHeight < 48;

  function toEnd() {
    if (box) box.scrollTop = box.scrollHeight;
    atEnd = true;
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

<div class="wrap">
  <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
  <div class="scroll" bind:this={box} onscroll={() => box && (atEnd = nearEnd(box))} onclick={click}>
    {@render children()}
  </div>
  {#if !atEnd}
    <button class="end" onclick={toEnd} aria-label={tr("Naar het nieuwste", "To the newest")}><Icon name="chevron-down" size={18} /></button>
  {/if}
</div>

<style>
  .wrap { flex: 1; min-height: 0; position: relative; display: flex; }
  .scroll { flex: 1; overflow-y: auto; padding: var(--space-8) var(--space-16) var(--space-16); display: flex; flex-direction: column; gap: var(--space-12); }
  .end { position: absolute; right: var(--space-16); bottom: var(--space-12); width: 40px; height: 40px; border-radius: 50%; display: flex; align-items: center; justify-content: center; background: var(--smoke); border: 1px solid var(--line2); box-shadow: var(--shadow-popover); }
</style>
