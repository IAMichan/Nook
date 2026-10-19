<script lang="ts">
  import { nook } from "../lib/state.svelte";
  import Composer from "./Composer.svelte";
  import MessageView from "./MessageView.svelte";
  import Orb from "./Orb.svelte";

  let { compact = false, autofocus = false }: { compact?: boolean; autofocus?: boolean } = $props();
  let scroller: HTMLDivElement;

  const starters = [
    "Wat staat er vandaag open?",
    "Schrijf een korte mail dat ik later ben",
    "Leg uit wat een API-sleutel is",
  ];

  // Mee naar beneden scrollen terwijl het antwoord binnenkomt.
  $effect(() => {
    void nook.active?.messages.length;
    void Object.values(nook.streaming).join("").length;
    queueMicrotask(() => scroller && (scroller.scrollTop = scroller.scrollHeight));
  });
</script>

<div class="chat">
  <div class="messages" bind:this={scroller}>
    {#if !nook.active || nook.active.messages.length === 0}
      <div class="empty">
        <Orb size={44} />
        <p class="muted">Waar kan ik je mee helpen?</p>
        <div class="starters">
          {#each starters as s (s)}<button onclick={() => nook.ask(s)}>{s}</button>{/each}
        </div>
      </div>
    {:else}
      {#each nook.active.messages as message (message.id)}
        <MessageView {message} nookId={nook.active.id} />
      {/each}
    {/if}
    {#if nook.error}<div class="err">{nook.error}</div>{/if}
  </div>
  <Composer {compact} {autofocus} />
</div>

<style>
  .chat { display: flex; flex-direction: column; height: 100%; min-height: 0; }
  .messages { flex: 1; overflow-y: auto; padding: 12px 16px; min-height: 0; }
  .empty { height: 100%; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 10px; }
  .starters { display: flex; flex-wrap: wrap; gap: 6px; justify-content: center; max-width: 460px; }
  .starters button { border-radius: 999px; font-size: 12px; }
  .err { color: var(--coral); padding: 6px 0; }
</style>
