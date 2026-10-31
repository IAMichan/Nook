<script lang="ts">
  // Gamer Mode: on or off, how often Nook looks at the game, and whether new coaching shows as a notice.
  import { games } from "../../lib/games";
  import { gamer } from "../../lib/gamer.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import { nook } from "../../lib/state.svelte";

  $effect(() => gamer.start());

  const prefs = $derived(gamer.view?.prefs);
  const canSee = $derived(!!nook.info?.capabilities.screenPart);

  function save(change: Partial<NonNullable<typeof prefs>>) {
    if (!prefs) return;
    gamer.run(() => games.savePrefs({ ...prefs, ...change }), tr("Kon Gamer Mode niet opslaan", "Could not save Gamer Mode"));
  }
</script>

<h2>Gamer Mode</h2>
<p class="muted">
  {tr(
    "Terwijl Valorant voorop staat, maakt Nook af en toe een schermafbeelding van je eigen scherm en laat het brein dat je koos die lezen. Nook leest nooit het geheugen van de game en stuurt er niets naartoe.",
    "While Valorant is in front, Nook takes a screenshot of your own screen now and then and lets the brain you chose read it. Nook never reads the game's memory and never sends it input.",
  )}
</p>
{#if prefs}
  <div class="group">
    <label class="row">
      <span>{tr("Gamer Mode aan", "Gamer Mode enabled")}</span>
      <input type="checkbox" checked={prefs.enabled} disabled={!canSee} onchange={(e) => save({ enabled: e.currentTarget.checked })} />
    </label>
    <label class="row">
      <span>{tr("Kijk elke", "Look every")}</span>
      <span class="inline">
        <select value={String(prefs.intervalSecs)} onchange={(e) => save({ intervalSecs: Number(e.currentTarget.value) })}>
          {#each [3, 5, 10, 20, 30, 60] as s (s)}<option value={String(s)}>{s} {tr("seconden", "seconds")}</option>{/each}
        </select>
      </span>
    </label>
    <label class="row">
      <span>{tr("Laat nieuwe coaching zien als melding", "Show new coaching as a notice")}</span>
      <input type="checkbox" checked={prefs.notify} onchange={(e) => save({ notify: e.currentTarget.checked })} />
    </label>
  </div>
  <p class="faint note">
    {tr(
      "Elke blik is een vraag aan je brein met een afbeelding: met een externe dienst kost dat tokens, lokaal heb je een model nodig dat kan zien (zoals llava of qwen2.5-vl). Staat je scherm op 'alleen op deze computer', dan kijkt Nook niet mee met een extern brein.",
      "Each look is one request with an image to your brain: with an external service that costs tokens, locally you need a model that can see (such as llava or qwen2.5-vl). If your screen is set to stay on this computer, Nook won't look with an external brain.",
    )}
  </p>
  {#if !canSee}<p class="faint note">{tr("Op dit apparaat kan Nook niet naar het scherm kijken.", "Nook can't look at the screen on this device.")}</p>{/if}
{/if}
