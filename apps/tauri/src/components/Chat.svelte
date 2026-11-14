<script lang="ts">
  // The chat: messages that follow the answer down, and while it is empty Nook's home (`NookTab.emptyState` on the
  // Mac): the date, a greeting that says how much waits for you, "For you" (the inbox's top rows), "Where things
  // stand" (agents, calendar, music) and starters. The first time, a welcome card leads to the three setup steps.
  import { brainApi } from "../lib/brain";
  import { nook } from "../lib/state.svelte";
  import { locale, tr } from "../lib/i18n.svelte";
  import { inbox } from "../lib/inbox.svelte";
  import { registerInboxSources } from "../lib/inbox-sources";
  import type { Target } from "../lib/inbox";
  import { renderMarkdown } from "../lib/markdown";
  import Composer from "./Composer.svelte";
  import MessageView from "./MessageView.svelte";
  import Onboarding from "./Onboarding.svelte";
  import ForYou from "./ForYou.svelte";
  import HomeGlance from "./HomeGlance.svelte";
  import StarterGrid from "./StarterGrid.svelte";

  let { compact = false, autofocus = false, onopen }: { compact?: boolean; autofocus?: boolean; onopen?: (target: Target) => void } = $props();
  let scroller: HTMLDivElement;
  let starters = $state<string[]>([]);
  let onboarding = $state(false);
  /// A note a "For you" row opened, read right here.
  let reading = $state<{ title: string; markdown: string } | null>(null);

  const empty = $derived(!nook.active || nook.active.messages.length === 0);
  const welcome = $derived(!!nook.settings && !nook.settings.onboardingDone && !compact);
  const caps = $derived(nook.info?.capabilities);
  // The home's rows and cards are for the main window; the bar has its own Home tab.
  const home = $derived(!compact && !!onopen);

  $effect(() => {
    if (empty) brainApi.suggestions().then((s) => (starters = s)).catch(() => (starters = []));
  });

  $effect(() => {
    if (!home) return;
    registerInboxSources();
    inbox.start();
    return () => inbox.stop();
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

  // "Monday 19 October", then a calm greeting with how many things wait for you.
  let now = $state(new Date());
  $effect(() => {
    const timer = setInterval(() => (now = new Date()), 60_000);
    return () => clearInterval(timer);
  });
  const dateLine = $derived.by(() => {
    const line = now.toLocaleDateString(locale(), { weekday: "long", day: "numeric", month: "long" });
    return line.charAt(0).toLocaleUpperCase(locale()) + line.slice(1);
  });
  const forYou = $derived(home ? inbox.ranked.shown.slice(0, 6) : []);
  const greeting = $derived.by(() => {
    const hour = now.getHours();
    const hello = hour < 6 ? tr("Goedenacht", "Good night") : hour < 12 ? tr("Goedemorgen", "Good morning") : hour < 18 ? tr("Goedemiddag", "Good afternoon") : tr("Goedenavond", "Good evening");
    const n = forYou.length;
    if (n === 0) return tr("{hello}. Niets dat op je wacht.", "{hello}. Nothing waiting for you.", { hello });
    const what = [
      tr("Eén ding", "One thing"), tr("Twee dingen", "Two things"), tr("Drie dingen", "Three things"),
      tr("Vier dingen", "Four things"), tr("Vijf dingen", "Five things"),
    ][n - 1] ?? tr("{n} dingen", "{n} things", { n });
    return tr("{hello}. {what} voor je.", "{hello}. {what} for you.", { hello, what });
  });

  function open(target: Target | void) {
    if (!target) return;
    if (target.kind === "markdown") reading = { title: target.title, markdown: target.markdown };
    else onopen?.(target);
  }

  const lastId = $derived(nook.active?.messages[nook.active.messages.length - 1]?.id);
</script>

<div class="chat" class:compact>
  <div class="messages" bind:this={scroller} onscroll={onScroll}><div class="reading-column">
    {#if empty}
      <div class="empty" class:home>
        {#if !compact}
          <div class="hello">
            <span class="date">{dateLine}</span>
            <h1>{home ? greeting : tr("Waar kan ik mee helpen?", "What can I help with?")}</h1>
          </div>
        {/if}
        {#if reading}
          <div class="reading">
            <div class="reading-head"><span class="label">{reading.title}</span><button class="ghost" onclick={() => (reading = null)}>{tr("Sluiten", "Close")}</button></div>
            <div class="markdown">{@html renderMarkdown(reading.markdown)}</div>
          </div>
        {/if}
        {#if welcome}
          <div class="welcome">
            <p>{tr("Koppel een brein om te beginnen. Voeg je tools toe als je er klaar voor bent, zodat Nook je dag kan helpen.", "Connect a brain to get started. Add your tools when you're ready, so Nook can help with your day.")}</p>
            <dl>
              <dt>1 · {tr("Brein", "Brain")}</dt><dd class:ok={nook.info?.brainReady}>{nook.info?.brainReady ? tr("Klaar", "Ready") : tr("Kies een gratis lokaal model of een AI-aanbieder", "Choose a free local model or an AI provider")}</dd>
              {#if caps?.screenReading}<dt>2 · {tr("Schermcontext", "Screen context")}</dt><dd class:ok={nook.settings?.liveScreen}>{nook.settings?.liveScreen ? tr("Aan", "On") : tr("Uit", "Off")}</dd>{/if}
              <dt>{caps?.screenReading ? 3 : 2} · {tr("Koppelingen", "Connections")}</dt><dd>{tr("Mail, GitHub, Stripe… (optioneel)", "Mail, GitHub, Stripe… (optional)")}</dd>
            </dl>
            <div class="buttons">
              <button class="ghost" onclick={() => nook.saveSettings({ onboardingDone: true })}>{tr("Later instellen", "Set up later")}</button>
              <button class="primary" onclick={() => (onboarding = true)}>{tr("Nook instellen", "Set up Nook")}</button>
            </div>
          </div>
        {:else if compact}
          <p class="empty-note">{tr("Je tools en ideeën, één gesprek verderop.", "Your tools and ideas, one conversation away.")}</p>
        {/if}
        {#if home && forYou.length}
          <div class="section-label">{tr("Voor jou", "For you")}</div>
          <ForYou items={forYou} onopen={open} />
        {/if}
        {#if home}
          <div class="section-label">{tr("Zo staat het ervoor", "Where things stand")}</div>
          <HomeGlance onopen={open} />
        {/if}
        {#if starters.length}
          {#if !compact}<div class="section-label">{tr("Begin met", "Start with")}</div>{/if}
          <StarterGrid {starters} {compact} onask={(s) => nook.ask(s)} />
        {/if}
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
  /* The empty chat reads from the top left, as on the Mac: date, greeting, then the sections 24 px apart. */
  .empty { display: flex; flex-direction: column; align-items: stretch; padding: var(--space-24) 0 var(--space-8); }
  .hello { display: flex; flex-direction: column; gap: var(--space-4); padding: 0 var(--space-2); }
  .date { font: var(--text-label); color: var(--text3); }
  h1 { margin: 0; font: var(--text-display); color: var(--paper); letter-spacing: -0.2px; }
  .section-label { font: var(--text-label); color: var(--text3); padding: var(--space-24) var(--space-2) var(--space-8); }
  .welcome { margin-top: var(--space-24); border: 1px solid var(--line2); background: var(--graphite); border-radius: var(--radius-panel); padding: 18px; line-height: 1.6; display: flex; flex-direction: column; gap: var(--space-8); }
  .welcome p { margin: 0; }
  dl { display: grid; grid-template-columns: auto 1fr; gap: 4px 12px; margin: 0; font: var(--text-detail); }
  dt { color: var(--text3); }
  dd { margin: 0; color: var(--text2); }
  dd.ok { color: var(--mint); }
  .buttons { display: flex; justify-content: flex-end; gap: var(--space-8); }
  .reading { margin-top: var(--space-24); background: var(--field); border-radius: var(--radius-panel); padding: var(--space-12) var(--space-16); }
  .reading-head { display: flex; align-items: center; justify-content: space-between; gap: var(--space-8); margin-bottom: var(--space-8); }
  .reading-head .label { font: var(--text-title); }
  .err { color: var(--coral); padding: 6px 0; }
  .empty-note { font: var(--text-detail); color: var(--text2); margin: 0 0 var(--space-12); text-align: center; }
  .compact .messages { padding: 12px 16px; }
  .compact .empty { padding: 8px 0; justify-content: center; flex: 1; }
  @media (max-width: 640px) {
    .messages { padding: 20px 16px; }
    .empty { padding: var(--space-16) 0; }
  }
</style>
