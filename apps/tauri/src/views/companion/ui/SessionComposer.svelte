<script lang="ts">
  // The composer of every conversation (`SessionComposer`): a dark box with a light along its top edge, the field, and a
  // round send button that turns into Stop while work runs and nothing is typed. With `controls` a row of quiet choices
  // sits under the field.
  import type { Snippet } from "svelte";
  import { tr } from "../../../lib/i18n.svelte";
  import Ico from "./Ico.svelte";
  import DictationButton from "./DictationButton.svelte";

  let {
    value = $bindable(""), placeholder, onsend, onstop, canSend = true, sending = false, minHeight = 32, controls, autofocus = false, attached = false,
  }: {
    value: string;
    placeholder: string;
    onsend: (text: string) => void;
    /** Shown instead of Send while nothing is typed. */
    onstop?: () => void;
    canSend?: boolean;
    sending?: boolean;
    minHeight?: number;
    controls?: Snippet;
    autofocus?: boolean;
    /** A picture or file waits to go: Send works without words. */
    attached?: boolean;
  } = $props();
  let field = $state<HTMLTextAreaElement | null>(null);
  let focused = $state(false);
  const typed = $derived(value.trim().length > 0 || attached);
  $effect(() => { if (autofocus) field?.focus(); });

  function send() {
    if (!typed || !canSend || sending) return;
    onsend(value.trim());
  }
</script>

<!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
<div class="box" class:focused class:withcontrols={!!controls} onclick={() => field?.focus()}>
  {#if controls}
    <textarea bind:this={field} bind:value {placeholder} rows="1" style:min-height="{minHeight}px" onfocus={() => (focused = true)} onblur={() => (focused = false)}></textarea>
    <div class="controls">
      <span class="scrollrow">{@render controls()}</span>
      {@render button()}
    </div>
  {:else}
    <div class="line">
      <textarea bind:this={field} bind:value {placeholder} rows="1" style:min-height="{minHeight}px" onfocus={() => (focused = true)} onblur={() => (focused = false)}></textarea>
      {@render button()}
    </div>
  {/if}
</div>

{#snippet button()}
  <DictationButton bind:value />
  {#if onstop && !typed}
    <button class="send on" aria-label={tr("Stop", "Stop")} onclick={(e) => { e.stopPropagation(); onstop?.(); }}><span class="stopsq"></span></button>
  {:else}
    <button class="send" class:on={typed && canSend} disabled={!typed || !canSend || sending} aria-label={tr("Verstuur", "Send")} onclick={(e) => { e.stopPropagation(); send(); }}>
      {#if sending}<span class="spin"></span>{:else}<Ico name="arrow-up" size={14} stroke={3} />{/if}
    </button>
  {/if}
{/snippet}

<style>
  .box { position: relative; background: var(--surface); border-radius: 16px; border: 1px solid var(--field-stroke); padding: 8px 8px 8px 16px; transition: border-color var(--reveal); }
  .box.withcontrols { padding-top: 16px; }
  .box::before { content: ""; position: absolute; inset: -1px; border-radius: 16px; padding: 1px; background: linear-gradient(rgba(255, 255, 255, 0.06), transparent 50%); -webkit-mask: linear-gradient(#000 0 0) content-box, linear-gradient(#000 0 0); -webkit-mask-composite: xor; mask: linear-gradient(#000 0 0) content-box, linear-gradient(#000 0 0); mask-composite: exclude; pointer-events: none; }
  .box.focused { border-color: rgba(244, 243, 247, 0.28); }
  .line { display: flex; align-items: flex-end; gap: 8px; }
  textarea { flex: 1; min-width: 0; resize: none; max-height: 150px; field-sizing: content; padding: 5px 0; line-height: 1.4; }
  .withcontrols textarea { width: 100%; box-sizing: border-box; max-height: 240px; }
  .controls { display: flex; align-items: center; gap: 4px; margin: 12px 0 0 -8px; }
  .controls :global(.pill) { flex: none; }
  .scrollrow { flex: 1; min-width: 0; display: flex; align-items: center; gap: 4px; overflow-x: auto; scrollbar-width: none; }
  .scrollrow::-webkit-scrollbar { display: none; }
  .send { width: 34px; height: 34px; border-radius: 50%; flex: none; display: inline-flex; align-items: center; justify-content: center; background: var(--smoke) !important; color: var(--text3) !important; }
  .send:disabled { opacity: 1 !important; }
  .send.on { background: var(--iris) !important; color: var(--on-iris) !important; }
  .stopsq { width: 11px; height: 11px; border-radius: 2px; background: var(--on-iris); }
  .spin { width: 14px; height: 14px; border-radius: 50%; border: 2px solid var(--text3); border-top-color: transparent; animation: spin 0.8s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
</style>
