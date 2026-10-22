<script lang="ts">
  // De chat: berichten met mee-scrollen, startvragen die bij het moment passen, en de eerste keer een welkomstkaart
  // die naar de drie instelstappen leidt.
  import { brainApi } from "../lib/brain";
  import { nook } from "../lib/state.svelte";
  import Composer from "./Composer.svelte";
  import MessageView from "./MessageView.svelte";
  import Onboarding from "./Onboarding.svelte";
  import Orb from "./Orb.svelte";

  let { compact = false, autofocus = false }: { compact?: boolean; autofocus?: boolean } = $props();
  let scroller: HTMLDivElement;
  let starters = $state<string[]>([]);
  let onboarding = $state(false);

  const empty = $derived(!nook.active || nook.active.messages.length === 0);
  const welcome = $derived(!!nook.settings && !nook.settings.onboardingDone && !compact);
  const caps = $derived(nook.info?.capabilities);

  $effect(() => {
    if (empty) brainApi.suggestions().then((s) => (starters = s)).catch(() => (starters = []));
  });

  // Follow the answer down while it comes in, but only while the view is at the bottom: someone who scrolled up to
  // read keeps their place. A new message of their own, or another Nook, always scrolls down.
  let atEnd = true;
  const onScroll = () => {
    if (scroller) atEnd = scroller.scrollTop + scroller.clientHeight >= scroller.scrollHeight - 48;
  };
  let lastCount = 0;
  let lastNook: string | null = null;
  $effect(() => {
    const shown = nook.activeId;
    const count = nook.active?.messages.length ?? 0;
    for (const id in nook.streaming) void nook.streaming[id]?.length;
    if (count > lastCount || shown !== lastNook) atEnd = true;
    lastCount = count;
    lastNook = shown;
    if (atEnd) queueMicrotask(() => scroller && (scroller.scrollTop = scroller.scrollHeight));
  });

  const lastId = $derived(nook.active?.messages[nook.active.messages.length - 1]?.id);
</script>

<div class="chat">
  <div class="messages" bind:this={scroller} onscroll={onScroll}>
    {#if empty}
      <div class="empty">
        <Orb size={44} />
        {#if welcome}
          <div class="welcome">
            <p>Ik ben je assistent. Ik ken je agenda, je open punten en wat je me vertelt, dus vraag me gewoon alles.</p>
            <dl>
              <dt>1 · brein</dt><dd class:ok={nook.info?.brainReady}>{nook.info?.brainReady ? "klaar" : "kies een lokaal model (gratis) of een externe AI"}</dd>
              {#if caps?.screenReading}<dt>2 · scherm lezen</dt><dd class:ok={nook.settings?.liveScreen}>{nook.settings?.liveScreen ? "aan" : "uit"}</dd>{/if}
              <dt>{caps?.screenReading ? 3 : 2} · koppelingen</dt><dd>mail, GitHub, Stripe… (optioneel)</dd>
            </dl>
            <div class="buttons">
              <button class="ghost" onclick={() => nook.saveSettings({ onboardingDone: true })}>Later</button>
              <button class="primary" onclick={() => (onboarding = true)}>Instellen</button>
            </div>
          </div>
        {:else}
          <p class="muted">Waar kan ik je mee helpen?</p>
        {/if}
        <div class="starters">
          {#each starters as s (s)}<button onclick={() => nook.ask(s)}>{s}</button>{/each}
        </div>
      </div>
    {:else}
      {#each nook.active!.messages as message (message.id)}
        <MessageView {message} nookId={nook.active!.id} last={message.id === lastId} />
      {/each}
    {/if}
    {#if nook.error}<div class="err">{nook.error}</div>{/if}
  </div>
  <Composer {compact} {autofocus} />
  {#if onboarding}<Onboarding onclose={() => (onboarding = false)} />{/if}
</div>

<style>
  .chat { position: relative; display: flex; flex-direction: column; height: 100%; min-height: 0; }
  .messages { flex: 1; overflow-y: auto; padding: 12px 16px; min-height: 0; }
  .empty { min-height: 100%; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 10px; }
  .starters { display: flex; flex-wrap: wrap; gap: 6px; justify-content: center; max-width: 460px; }
  .starters button { border-radius: 999px; font-size: 12px; }
  .welcome { max-width: 440px; border: 1px solid var(--line2); background: var(--field); border-radius: 14px; padding: 14px 16px; display: flex; flex-direction: column; gap: 8px; }
  .welcome p { margin: 0; }
  dl { display: grid; grid-template-columns: auto 1fr; gap: 4px 12px; margin: 0; font-size: 12px; }
  dt { color: var(--text3); }
  dd { margin: 0; color: var(--text2); }
  dd.ok { color: var(--mint); }
  .buttons { display: flex; justify-content: flex-end; gap: 8px; }
  .err { color: var(--coral); padding: 6px 0; }
</style>
