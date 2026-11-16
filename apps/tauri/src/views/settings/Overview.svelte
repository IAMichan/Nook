<script lang="ts">
  // Overview, the first page of Settings (`startSection` on the Mac): what needs you first, then one card per main page
  // with how it stands, each opening that page.
  import { nook } from "../../lib/state.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import type { SettingsSectionId } from "../../lib/shell-routes";
  import Icon from "../../components/Icon.svelte";

  let { onopen = () => {} }: { onopen?: (id: SettingsSectionId) => void } = $props();

  type IconName = "brain" | "link" | "terminal" | "memory" | "voice" | "hand" | "settings" | "sparkle";
  interface Card { id: SettingsSectionId; icon: IconName; title: string; detail: string; todo?: boolean }

  const brainReady = $derived(!!nook.info?.brainReady);
  const cards = $derived<Card[]>([
    {
      id: "brain", icon: "brain", title: tr("Brein", "Brain"), todo: !brainReady,
      detail: brainReady ? (nook.info?.brainLabel ?? tr("Klaar", "Ready")) : tr("Kies een gratis lokaal model of een AI-aanbieder", "Choose a free local model or an AI provider"),
    },
    { id: "accounts", icon: "link", title: tr("Accounts & koppelingen", "Accounts & connections"), detail: tr("Mail, agenda, GitHub en je chat-apps", "Mail, calendar, GitHub and your chat apps") },
    { id: "agents", icon: "terminal", title: "Coding agents", detail: tr("Claude Code, Codex, Gemini CLI en meer", "Claude Code, Codex, Gemini CLI and more") },
    { id: "assistant", icon: "sparkle", title: tr("Assistent", "Assistant"), detail: tr("Wat Nook voor je doet en hoe", "What Nook does for you, and how") },
    { id: "memory", icon: "memory", title: tr("Geheugen", "Memory"), detail: tr("Wat Nook over je weet", "What Nook knows about you") },
    { id: "voice", icon: "voice", title: tr("Stem en geluid", "Voice & sound"), detail: tr("Praten en voorlezen", "Talking and reading aloud") },
    { id: "privacy", icon: "hand", title: tr("Privacy & beveiliging", "Privacy & security"), detail: tr("Wat Nook mag zien en versturen", "What Nook may see and send") },
    { id: "general", icon: "settings", title: tr("Algemeen", "General"), detail: tr("Taal, sneltoetsen en opstarten", "Language, shortcuts and startup") },
  ]);
</script>

<h2>{tr("Overzicht", "Overview")}</h2>

<h3>{tr("Heeft je aandacht nodig", "Needs your attention")}</h3>
<div class="group">
  {#if brainReady}
    <div class="row status">
      <span class="state ok"><Icon name="circle-check" size={16} /></span>
      <span class="text"><span>{tr("Alles werkt", "Everything works")}</span><span class="faint">{tr("Niets heeft je nu nodig.", "Nothing needs you right now.")}</span></span>
    </div>
  {:else}
    <div class="row status">
      <span class="state todo"><Icon name="alert" size={16} /></span>
      <span class="text"><span>{tr("Nook heeft nog geen brein", "Nook has no brain yet")}</span><span class="faint">{tr("Zonder brein kan Nook niet antwoorden.", "Without a brain, Nook can't answer.")}</span></span>
      <button class="primary" onclick={() => onopen("brain")}>{tr("Kies een brein", "Choose a brain")}</button>
    </div>
  {/if}
</div>

<h3>{tr("In één oogopslag", "At a glance")}</h3>
<div class="cards">
  {#each cards as card (card.id)}
    <button class="card" onclick={() => onopen(card.id)}>
      <span class="tile"><Icon name={card.icon} size={16} /></span>
      <span class="text">
        <span class="title">{card.title}</span>
        <span class="detail" class:todo={card.todo}>{card.detail}</span>
      </span>
      <span class="go"><Icon name="chevron-right" size={14} /></span>
    </button>
  {/each}
</div>

<style>
  .status { flex-wrap: nowrap !important; justify-content: flex-start !important; }
  .status .text { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: var(--space-2); }
  .status .text .faint { font: var(--text-detail); }
  .state { display: grid; place-items: center; flex: none; }
  .state.ok { color: var(--mint); }
  .state.todo { color: var(--amber); }
  .cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); gap: var(--space-8); margin-top: var(--space-12); }
  .card { display: flex; align-items: center; gap: var(--space-12); padding: var(--space-12); text-align: left; background: var(--graphite); border: 1px solid var(--line2); border-radius: var(--radius-card); }
  .card:hover:not(:disabled) { background: var(--smoke); border-color: var(--line2); }
  .tile { display: grid; place-items: center; width: 30px; height: 30px; flex: none; border-radius: var(--radius-control); background: var(--smoke); color: var(--text2); }
  .card .text { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: var(--space-2); }
  .card .title { font: var(--text-body); font-weight: 500; color: var(--paper); }
  .card .detail { font: var(--text-detail); color: var(--text2); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .card .detail.todo { color: var(--amber); }
  .go { color: var(--text3); opacity: 0; transition: opacity 120ms ease; }
  .card:hover .go, .card:focus-visible .go { opacity: 1; }
</style>
