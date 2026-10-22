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

<div class="chat" class:compact>
  <div class="messages" bind:this={scroller} onscroll={onScroll}><div class="reading-column">
    {#if empty}
      <div class="empty">
        <div class="welcome-orb"><Orb size={compact ? 44 : 64} /></div>
        <div class="greeting"><span class="eyebrow">A LITTLE SPACE FOR EVERYTHING</span><h1>What is on your mind?</h1><p>Think it through. Make a plan. Take the next step.</p></div>
        {#if welcome}
          <div class="welcome">
            <p>Connect a brain to get started. Add your tools when you're ready, so Nook can help with your day.</p>
            <dl>
              <dt>1 · Brain</dt><dd class:ok={nook.info?.brainReady}>{nook.info?.brainReady ? "Ready" : "Choose a free local model or an AI provider"}</dd>
              {#if caps?.screenReading}<dt>2 · Screen context</dt><dd class:ok={nook.settings?.liveScreen}>{nook.settings?.liveScreen ? "On" : "Off"}</dd>{/if}
              <dt>{caps?.screenReading ? 3 : 2} · Connections</dt><dd>Mail, GitHub, Stripe… (optional)</dd>
            </dl>
            <div class="buttons">
              <button class="ghost" onclick={() => nook.saveSettings({ onboardingDone: true })}>Set up later</button>
              <button class="primary" onclick={() => (onboarding = true)}>Set up Nook</button>
            </div>
          </div>
        {:else}
          <p class="empty-note">Your tools and ideas, one conversation away.</p>
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
  </div></div>
  <Composer {compact} {autofocus} />
  {#if onboarding}<Onboarding onclose={() => (onboarding = false)} />{/if}
</div>

<style>
  .chat { position: relative; display: flex; flex-direction: column; height: 100%; min-height: 0; }
  .messages { flex: 1; display: flex; flex-direction: column; overflow-y: auto; padding: 28px 32px; min-height: 0; overflow-wrap: anywhere; }
  .reading-column { flex: 1; display: flex; flex-direction: column; width: 100%; max-width: 760px; margin: 0 auto; }
  .empty { flex: 1; padding: 32px 0; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 20px; }
  .starters { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px; width: 100%; max-width: 520px; }
  .starters button { border-radius: var(--radius-card); font-size: 12px; padding: 14px 16px; text-align: left; background: transparent; color: var(--text2); line-height: 1.5; }
  .starters button:hover { color: var(--paper); }
  .welcome { width: 100%; max-width: 520px; border: 1px solid var(--line2); background: var(--graphite); border-radius: var(--radius); padding: 18px; line-height: 1.6; display: flex; flex-direction: column; gap: 8px; }
  .welcome p { margin: 0; }
  dl { display: grid; grid-template-columns: auto 1fr; gap: 4px 12px; margin: 0; font-size: 12px; }
  dt { color: var(--text3); }
  dd { margin: 0; color: var(--text2); }
  dd.ok { color: var(--mint); }
  .buttons { display: flex; justify-content: flex-end; gap: 8px; }
  .err { color: var(--coral); padding: 6px 0; }
  .welcome-orb { padding: 12px; }
  .greeting { text-align: center; }
  .eyebrow { font-size: 9px; font-weight: 600; letter-spacing: 2px; color: var(--text3); }
  h1 { font-size: clamp(24px, 3vw, 34px); font-weight: 550; letter-spacing: -1.1px; margin: 12px 0 10px; }
  .greeting p, .empty-note { font-size: 12px; line-height: 1.6; color: var(--text2); margin: 0; text-align: center; }
  .empty-note { display: none; }
  .compact .messages { padding: 12px 16px; }
  .compact .empty { padding: 8px 0; gap: 10px; }
  .compact .greeting, .compact .welcome-orb { display: none; }
  .compact .empty-note { display: block; }
  .compact .starters { display: flex; flex-wrap: wrap; justify-content: center; }
  .compact .starters button { padding: 6px 12px; border-radius: 999px; }
  @media (max-width: 640px) {
    .messages { padding: 20px 16px; }
    .empty { padding: 20px 0; }
    .starters { grid-template-columns: minmax(0, 1fr); }
  }
</style>
