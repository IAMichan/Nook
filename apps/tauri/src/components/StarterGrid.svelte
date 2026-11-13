<script lang="ts">
  // "Start with" on the empty Nook chat (`SuggestionGrid` on the Mac): starters two per row, each with the icon of what
  // it is about; under the pointer it brightens and shows an arrow. In the bar (`compact`) they are small pills.
  import Icon from "./Icon.svelte";

  let { starters, onask, compact = false }: { starters: string[]; onask: (text: string) => void; compact?: boolean } = $props();

  type IconName = "message" | "calendar" | "code" | "agents" | "note" | "tasks" | "globe" | "chart" | "sparkle";
  // The icon of what a starter is about, from its words (in any of Nook's languages); a sparkle for the rest.
  const topics: [RegExp, IconName][] = [
    [/mail|bericht|message|nachricht|correo|whatsapp|inbox/i, "message"],
    [/agenda|calendar|kalender|calendrier|calendario|meeting|vergader|réunion|reunión|afspra|termin/i, "calendar"],
    [/pull request|\bpr\b|code|github|commit|branch|bug/i, "code"],
    [/agent|claude|codex|gemini|cursor/i, "agents"],
    [/taak|taken|task|aufgabe|tâche|tarea|todo|to-do|plan/i, "tasks"],
    [/notitie|note|samenvat|summar|zusammenfass|résum|resum/i, "note"],
    [/web|zoek|search|such|cherch|busca|nieuws|news/i, "globe"],
    [/stripe|omzet|revenue|umsatz|chiffre|ingres|cijfer|stat/i, "chart"],
  ];
  const icon = (text: string): IconName => topics.find(([re]) => re.test(text))?.[1] ?? "sparkle";
</script>

<div class="starters" class:compact>
  {#each starters as s (s)}
    <button onclick={() => onask(s)}>
      {#if !compact}<span class="logo"><Icon name={icon(s)} size={14} /></span>{/if}
      <span class="text">{s}</span>
      {#if !compact}<span class="go" aria-hidden="true">↗</span>{/if}
    </button>
  {/each}
</div>

<style>
  .starters { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: var(--space-8); width: 100%; }
  .starters button { display: flex; align-items: center; gap: var(--space-8); min-height: 52px; padding: var(--space-8); text-align: left; background: var(--field); border: 0; border-radius: var(--radius-panel); color: var(--text-strong); font: var(--text-body); }
  .starters button:hover:not(:disabled) { background: var(--graphite); color: var(--paper); border-color: transparent; }
  .logo { display: grid; place-items: center; width: 26px; height: 26px; flex: none; border-radius: var(--radius-control); background: color-mix(in srgb, var(--text2) 12%, transparent); color: var(--text2); }
  .text { flex: 1; min-width: 0; overflow: hidden; display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; }
  .go { flex: none; font-size: 11px; font-weight: 600; color: var(--text3); opacity: 0; transition: opacity 120ms ease; }
  .starters button:hover .go, .starters button:focus-visible .go { opacity: 1; }
  .compact { display: flex; flex-wrap: wrap; justify-content: center; }
  .compact button { min-height: 0; padding: var(--space-6) var(--space-12); border-radius: 999px; font: var(--text-detail); color: var(--text2); background: transparent; border: 1px solid var(--line2); }
  @media (max-width: 640px) { .starters:not(.compact) { grid-template-columns: minmax(0, 1fr); } }
</style>
