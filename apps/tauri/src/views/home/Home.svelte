<script lang="ts">
  // Home, the first tab of the bar. It answers three things at a glance: what matters (the inbox), what you use most
  // (your essentials), and where to go (one click on either). It stays dumb: the inbox ranks, the features provide.
  import { fade, fly } from "svelte/transition";
  import { cubicOut } from "svelte/easing";
  import { invoke } from "@tauri-apps/api/core";
  import { nook } from "../../lib/state.svelte";
  import { tr, locale } from "../../lib/i18n.svelte";
  import { inbox } from "../../lib/inbox.svelte";
  import { registerInboxSources } from "../../lib/inbox-sources";
  import { daypart, type Target } from "../../lib/inbox";
  import { available, essentials, type Feature } from "../../lib/features";
  import { services } from "../../lib/services";
  import { toast } from "../../lib/toast.svelte";
  import { companion as companionApi } from "../../lib/companion";
  import Markdown from "../../components/Markdown.svelte";
  import Orb, { type Mood } from "../../components/Orb.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import InboxCard from "./InboxCard.svelte";
  import Essentials from "./Essentials.svelte";
  import Customize from "./Customize.svelte";

  interface BuddyMomentView {
    id: string;
    kind: "morning" | "welcomeBack" | "breakTime" | "lateNight" | "fridayWrap" | "birthday" | "milestone";
    mood: Mood;
    line: string;
    action?: "today" | "agents" | "breathe" | null;
    actionTitle?: string | null;
    seconds: number;
    count: number;
    minutes: number;
  }

  let { onopen, compact = false }: { onopen: (target: Target) => void; compact?: boolean } = $props();

  let companion = $state(false);
  $effect(() => {
    companionApi.info().then((i) => (companion = i.client)).catch(() => {});
  });

  registerInboxSources();
  $effect(() => {
    inbox.start();
    return () => inbox.stop();
  });

  let now = $state(new Date());
  $effect(() => {
    const timer = setInterval(() => (now = new Date()), 60_000);
    return () => clearInterval(timer);
  });

  // Buddy moment (SV-19): fetched from Rust `buddy_moment`, gracefully falling back to null in preview mode.
  let buddy = $state<BuddyMomentView | null>(null);
  let dismissedBuddy = $state<string | null>(null);
  let breathStep = $state<0 | 1 | 2 | 3>(0);
  let breathTimers: ReturnType<typeof setTimeout>[] = [];

  function stopBreathing() {
    for (const t of breathTimers) clearTimeout(t);
    breathTimers = [];
    breathStep = 0;
  }

  function startBreathing() {
    stopBreathing();
    breathStep = 1;
    // 4s inhale, 4s hold, 6s exhale (matches macOS 4-4-6 breathing moment).
    breathTimers = [
      setTimeout(() => (breathStep = 2), 4_000),
      setTimeout(() => (breathStep = 3), 8_000),
      setTimeout(() => (breathStep = 1), 14_000),
      setTimeout(() => (breathStep = 2), 18_000),
      setTimeout(() => (breathStep = 3), 22_000),
      setTimeout(() => stopBreathing(), 28_000),
    ];
  }

  $effect(() => {
    if (nook.settings?.buddyMoments === false) {
      buddy = null;
      stopBreathing();
      return;
    }
    let alive = true;
    const poll = () => {
      invoke<BuddyMomentView | null>("buddy_moment")
        .then((m) => {
          if (!alive) return;
          if (!m || m.id === dismissedBuddy) {
            if (!breathStep) buddy = null;
            return;
          }
          buddy = m;
        })
        .catch(() => {
          // Graceful preview-mode fallback when Tauri command is unavailable.
        });
    };
    poll();
    const timer = setInterval(poll, 60_000);
    return () => {
      alive = false;
      clearInterval(timer);
      stopBreathing();
    };
  });

  const buddyLine = $derived.by(() => {
    if (breathStep === 1) return tr("Adem rustig in…", "Breathe in slowly…");
    if (breathStep === 2) return tr("Even vasthouden…", "Hold…");
    if (breathStep === 3) return tr("En langzaam uit…", "And slowly out…");
    return buddy?.line ?? "";
  });

  function dismissBuddy() {
    const id = buddy?.id;
    stopBreathing();
    buddy = null;
    if (id) {
      dismissedBuddy = id;
      invoke("buddy_moment", { dismissId: id }).catch(() => {});
    }
  }

  function runBuddyAction() {
    if (!buddy?.action) return;
    if (buddy.action === "breathe") {
      startBreathing();
    } else if (buddy.action === "agents") {
      onopen({ kind: "route", route: "agents" });
    } else if (buddy.action === "today") {
      onopen({ kind: "route", route: "chat" });
    }
  }

  let customizing = $state(false);
  let reading = $state<{ title: string; markdown: string } | null>(null);

  const all = $derived(available(nook.info?.capabilities, { companion }));
  const pinned = $derived(essentials(nook.settings?.homeEssentials, all));
  const name = $derived(nook.settings?.userName.trim() ?? "");
  const greeting = $derived.by(() => {
    const part = daypart(now.getHours());
    const hello = part === "morning" ? tr("Goedemorgen", "Good morning") : part === "afternoon" ? tr("Goedemiddag", "Good afternoon") : tr("Goedenavond", "Good evening");
    return name ? `${hello}, ${name}.` : `${hello}.`;
  });
  const date = $derived(now.toLocaleDateString(locale(), { weekday: "long", day: "numeric", month: "long" }));
  const count = $derived(inbox.ranked.shown.length);
  const line = $derived(
    inbox.loading
      ? tr("Even kijken wat er speelt…", "Taking a look at what's going on…")
      : count === 0
        ? tr("Niets wacht op je. De rest kan wachten.", "Nothing needs you right now. Everything else can wait.")
        : count === 1
          ? tr("Eén ding is je aandacht waard.", "One thing worth your attention.")
          : tr("{n} dingen die je aandacht waard zijn.", "{n} things worth your attention.", { n: count }),
  );

  async function openTarget(target: Target | void) {
    if (!target) return;
    if (target.kind === "markdown") reading = { title: target.title, markdown: target.markdown };
    else onopen(target);
  }

  async function openFeature(feature: Feature) {
    if (feature.target.kind !== "note") return onopen(feature.target);
    try {
      await services.toggleNote();
    } catch (e) {
      toast.error(tr("De Notetaker startte niet", "The Notetaker did not start"), e);
    }
  }
</script>

<div class="home" class:compact>
  <div class="glow" aria-hidden="true"></div>
  <div class="page">
    <header in:fly={{ y: 8, duration: 420, easing: cubicOut }}>
      <span class="date">{date}</span>
      <h1>{greeting}</h1>
      {#key line}<p class="line" in:fade={{ duration: 260 }}>{line}</p>{/key}
    </header>

    {#if buddy}
      <aside class="buddy-card" aria-label={tr("Moment van Nook", "Moment from Nook")} in:fly={{ y: 8, duration: 300, easing: cubicOut }} out:fade={{ duration: 160 }}>
        <Orb size={compact ? 28 : 34} mood={breathStep > 0 ? "breathe" : buddy.mood} />
        <p class="buddy-line">{buddyLine}</p>
        {#if buddy.action && buddy.actionTitle && breathStep === 0}
          <button type="button" class="buddy-action" onclick={runBuddyAction}>{buddy.actionTitle}</button>
        {/if}
        <button type="button" class="buddy-close" aria-label={tr("Sluiten", "Close")} onclick={dismissBuddy}>
          <Ico name="x" size={13} />
        </button>
      </aside>
    {/if}

    <div class="layout">
      <section class="inbox-col" aria-label={tr("Inbox", "Inbox")} in:fly={{ y: 12, duration: 480, delay: 70, easing: cubicOut }}>
        <InboxCard {compact} onopen={openTarget} />
      </section>
      <section class="essentials-col" aria-label={tr("Je essentials", "Your essentials")} in:fly={{ y: 12, duration: 480, delay: 140, easing: cubicOut }}>
        <Essentials {compact} features={pinned} onopen={openFeature} oncustomize={() => (customizing = true)} />
      </section>
    </div>
  </div>
</div>

{#if customizing}<Customize features={all} {pinned} onclose={() => (customizing = false)} />{/if}

{#if reading}
  <div class="backdrop" role="presentation" transition:fade={{ duration: 160 }} onclick={(e) => e.target === e.currentTarget && (reading = null)}>
    <div class="sheet" role="dialog" aria-modal="true" aria-label={reading.title} in:fly={{ y: 10, duration: 220, easing: cubicOut }}>
      <header class="sheet-head"><h3>{reading.title}</h3><button class="ghost" onclick={() => (reading = null)} aria-label={tr("Sluiten", "Close")}>✕</button></header>
      <div class="body"><Markdown text={reading.markdown} /></div>
    </div>
  </div>
{/if}

<style>
  /* Home lays itself out by its own width, so the same page fits the bar's panel and a large window. */
  .home { position: relative; height: 100%; overflow-y: auto; overflow-x: hidden; isolation: isolate; container-type: inline-size; }
  /* One soft light behind the greeting; it is the only decoration on the page. */
  .glow {
    position: absolute; z-index: -1; inset: -120px 0 auto 0; height: 560px; pointer-events: none;
    background:
      radial-gradient(520px 260px at 18% 30%, color-mix(in srgb, var(--violet) 13%, transparent), transparent 70%),
      radial-gradient(460px 240px at 72% 10%, color-mix(in srgb, var(--mint) 7%, transparent), transparent 70%);
    animation: breathe 14s ease-in-out infinite alternate;
  }
  @keyframes breathe { from { opacity: .75; transform: translateY(0); } to { opacity: 1; transform: translateY(14px); } }
  .page { max-width: 1120px; margin: 0 auto; padding: 64px 48px 56px; }
  header { margin-bottom: 40px; }
  .date { display: block; color: var(--text3); font-size: 12px; letter-spacing: .4px; margin-bottom: 10px; }
  h1 { margin: 0; font-size: 36px; font-weight: 600; letter-spacing: -1.1px; line-height: 1.12; }
  .line { margin: 12px 0 0; color: var(--text2); font-size: 16px; line-height: 1.45; max-width: 560px; }
  .buddy-card {
    display: flex; align-items: center; gap: var(--space-12); margin: 0 0 var(--space-24); padding: var(--space-12) var(--space-16);
    background: var(--surface); border: 1px solid var(--line2); border-radius: var(--radius-card);
  }
  .buddy-line { flex: 1; min-width: 0; margin: 0; font: var(--text-body); color: var(--paper); }
  .buddy-action {
    flex: none; padding: var(--space-6) var(--space-12); border: 1px solid var(--line2); border-radius: var(--radius-control);
    background: var(--smoke); color: var(--paper); font: var(--text-label); cursor: pointer;
  }
  .buddy-action:hover { background: var(--row-selected); }
  .buddy-close {
    flex: none; display: inline-flex; align-items: center; justify-content: center; width: 24px; height: 24px; padding: 0;
    border: none; border-radius: var(--radius-control); background: transparent; color: var(--text3); cursor: pointer;
  }
  .buddy-close:hover { background: var(--row-hover); color: var(--paper); }
  .compact .buddy-card { margin-bottom: var(--space-16); padding: var(--space-8) var(--space-12); gap: var(--space-8); }
  .layout { display: grid; grid-template-columns: minmax(0, 1.45fr) minmax(280px, 1fr); gap: 28px; align-items: start; }
  @container (max-width: 860px) {
    .page { padding: 40px 28px 36px; }
    .layout { grid-template-columns: minmax(0, 1.3fr) minmax(220px, 1fr); gap: 20px; }
  }
  @container (max-width: 600px) {
    .page { padding: 28px 16px 24px; }
    header { margin-bottom: 24px; }
    h1 { font-size: 26px; letter-spacing: -.7px; }
    .line { font-size: 14px; }
    .layout { grid-template-columns: minmax(0, 1fr); gap: 28px; }
  }
  /* In the bar: the same page, tighter, on the bar's black. */
  .compact .page { padding: 14px 18px 18px; }
  .compact header { margin-bottom: 16px; }
  .compact .date { font-size: 11px; margin-bottom: 4px; }
  .compact h1 { font-size: 22px; letter-spacing: -.5px; }
  .compact .line { font-size: 13px; margin-top: 6px; }
  .compact .glow { inset: -160px 0 auto 0; opacity: .7; }
  .backdrop { position: fixed; inset: 0; background: rgba(0, 0, 0, 0.55); display: grid; place-items: center; z-index: 50; padding: 16px; }
  .sheet { background: var(--graphite); border: 1px solid var(--line2); border-radius: var(--radius-panel); width: min(620px, 100%); max-height: 86vh; display: flex; flex-direction: column; overflow: hidden; box-shadow: var(--shadow-popover); }
  .sheet-head { display: flex; align-items: center; gap: 12px; padding: 18px 20px 10px; margin: 0; }
  .sheet-head h3 { margin: 0; font-size: 16px; flex: 1; min-width: 0; }
  .body { padding: 0 20px 20px; overflow-y: auto; }
</style>
