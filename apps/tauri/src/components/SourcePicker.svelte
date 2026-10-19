<script lang="ts">
  // De bronkiezer naast het invoerveld: welke bronnen deze Nook mag gebruiken. Automatisch = alles wat aan staat;
  // in je vraag kan het ook ("alleen mijn agenda en mail", "niet mijn scherm").
  import { brainApi, type SourceChoice, type SourceScope } from "../lib/brain";
  import { nook } from "../lib/state.svelte";

  let open = $state(false);
  let root: HTMLDivElement;
  let choices = $state<SourceChoice[]>([]);
  const scope = $derived<SourceScope>(nook.active?.scope ?? { mode: "automatic", included: [], excluded: [], focus: [] });
  const label = $derived(
    scope.mode === "only" ? `Alleen ${scope.included.length}` : scope.excluded.length ? `Zonder ${scope.excluded.length}` : "Automatisch",
  );

  async function toggle() {
    open = !open;
    if (open) choices = await brainApi.sourceChoices();
  }

  function allowed(id: string): boolean {
    if (scope.excluded.includes(id)) return false;
    return scope.mode !== "only" || scope.included.includes(id);
  }

  async function set(next: SourceScope | null) {
    const id = await nook.ensureActive();
    await brainApi.setScope(id, next);
    await nook.load(id);
  }

  function flip(id: string) {
    const excluded = allowed(id) ? [...scope.excluded, id] : scope.excluded.filter((e) => e !== id);
    const included = scope.mode === "only" && !allowed(id) ? [...scope.included, id] : scope.included;
    set({ ...scope, excluded, included });
  }
</script>

<svelte:window onclick={(e) => open && !root.contains(e.target as Node) && (open = false)} onkeydown={(e) => e.key === "Escape" && (open = false)} />

<div class="picker" bind:this={root}>
  <button class="chip" class:restricted={scope.mode === "only" || scope.excluded.length > 0} onclick={toggle} title="Welke bronnen deze Nook mag gebruiken">
    ◎ {label}
  </button>
  {#if open}
    <div class="menu">
      <button class="ghost row" onclick={() => set(null)}>{scope.mode === "automatic" && !scope.excluded.length ? "✓ " : ""}Automatisch</button>
      <div class="sep"></div>
      {#each choices as c (c.id)}
        <label class="row" class:private={c.private} title={c.private ? "Alleen op dit apparaat: een externe AI krijgt deze bron niet" : ""}>
          <input type="checkbox" checked={allowed(c.id) && !c.private} disabled={c.private} onchange={() => flip(c.id)} />
          {c.title}{c.private ? " 🔒" : ""}
        </label>
      {/each}
      <p class="faint hint">Of zeg het in je vraag: "alleen mijn agenda en mail".</p>
    </div>
  {/if}
</div>

<style>
  .picker { position: relative; }
  .chip { font-size: 11px; padding: 2px 8px; border-radius: 999px; background: none; color: var(--text3); }
  .chip.restricted { color: var(--amber); border-color: color-mix(in srgb, var(--amber) 40%, var(--line2)); }
  .menu { position: absolute; bottom: 26px; left: 0; z-index: 20; min-width: 220px; max-height: 320px; overflow-y: auto; background: var(--smoke); border: 1px solid var(--line2); border-radius: 10px; padding: 6px; }
  .row { display: flex; gap: 8px; align-items: center; width: 100%; text-align: left; padding: 4px 6px; font-size: 12px; }
  .row.private { color: var(--text3); }
  .sep { border-top: 1px solid var(--line2); margin: 4px 0; }
  .hint { font-size: 11px; margin: 6px; }
</style>
