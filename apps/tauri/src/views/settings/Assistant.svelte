<script lang="ts">
  // Assistent: wat Nook ziet (je schermen, het klembord, je bestanden, je gesprekken) en of hij meedenkt.
  import { nook } from "../../lib/state.svelte";
  import { services, type ServicePrefs, type ScreenStatus } from "../../lib/services";

  const s = $derived(nook.settings!);
  const caps = $derived(nook.info?.capabilities);
  let prefs = $state<ServicePrefs | null>(null);
  let screen = $state<ScreenStatus | null>(null);

  $effect(() => {
    services.prefs().then((p) => (prefs = p));
    services.screenStatus().then((st) => (screen = st));
    const timer = setInterval(() => services.screenStatus().then((st) => (screen = st)), 8000);
    return () => clearInterval(timer);
  });

  async function save(patch: Partial<ServicePrefs>) {
    if (!prefs) return;
    prefs = await services.savePrefs({ ...prefs, ...patch });
  }

  function unmute(id: string) {
    if (!prefs) return;
    const muted = { ...prefs.thinkAlongMuted };
    delete muted[id];
    save({ thinkAlongMuted: muted });
  }
</script>

<h2>Assistent</h2>

<h3>Wat Nook ziet</h3>
<div class="group">
  {#if caps?.screenReading}
    <label class="row">
      <span>Houd al mijn schermen bij<br /><small class="faint">Nook leest de tekst van al je vensters, op deze computer. Daardoor is een antwoord direct klaar.</small></span>
      <input type="checkbox" checked={s.liveScreen} onchange={(e) => nook.saveSettings({ liveScreen: e.currentTarget.checked })} />
    </label>
    <label class="row">
      <span>Gebruik mijn schermen bij elke vraag<br /><small class="faint">Uit: alleen als je naar iets verwijst ("dit", "hier", "die mail").</small></span>
      <input type="checkbox" checked={s.screenWithEveryQuestion} onchange={(e) => nook.saveSettings({ screenWithEveryQuestion: e.currentTarget.checked })} />
    </label>
    <div class="row">
      <span>Nu in beeld</span>
      <span class="faint now">{screen?.windows.length ? screen.windows.slice(0, 4).join(" · ") : "niets gelezen"}</span>
    </div>
    {#if screen?.status}<p class="faint note">{screen.status}</p>{/if}
  {:else}
    <p class="faint note">{caps?.notes?.screenReading ?? "Op dit apparaat kan Nook niet meekijken."}</p>
  {/if}
  {#if prefs && caps?.clipboard}
    <label class="row">
      <span>Klembord<br /><small class="faint">Wat je net kopieerde. Wachtwoorden die een wachtwoordbeheerder als geheim markeert, slaat Nook altijd over.</small></span>
      <input type="checkbox" checked={prefs.clipboard} onchange={(e) => save({ clipboard: e.currentTarget.checked })} />
    </label>
  {/if}
  {#if prefs && caps?.files}
    <label class="row">
      <span>Bestanden<br /><small class="faint">Zoeken en lezen in je thuismap, nooit in verborgen mappen, sleutels of wachtwoordexports.</small></span>
      <input type="checkbox" checked={prefs.files} onchange={(e) => save({ files: e.currentTarget.checked })} />
    </label>
  {/if}
  {#if prefs}
    <label class="row">
      <span>Gesprekken<br /><small class="faint">Wat de Notetaker noteerde, doorzoekbaar in de chat. Alleen op deze computer.</small></span>
      <input type="checkbox" checked={prefs.callNotes} onchange={(e) => save({ callNotes: e.currentTarget.checked })} />
    </label>
  {/if}
</div>

{#if caps?.screenReading}
  <h3>Meedenken</h3>
  <div class="group">
    <label class="row">
      <span>Denk mee terwijl ik werk<br /><small class="faint">Kan Nook iets overnemen of weet hij een slimmere aanpak, dan stelt hij het voor naast de balk. Zeg je vaker nee, dan houdt hij zich in. Stuurt af en toe de tekst van je voorste vensters naar je brein.</small></span>
      <input type="checkbox" checked={s.autoWatch} onchange={(e) => nook.saveSettings({ autoWatch: e.currentTarget.checked })} />
    </label>
    <label class="row">
      <span>Kleine dingen meteen doen<br /><small class="faint">Muziek, volume, een app, een herinnering of een open punt. Afspraken, mail, links, opdrachten en diensten vragen altijd eerst.</small></span>
      <input type="checkbox" checked={s.autoRunSafe} onchange={(e) => nook.saveSettings({ autoRunSafe: e.currentTarget.checked })} />
    </label>
    {#if prefs && Object.keys(prefs.thinkAlongMuted).length}
      <div class="row">
        <span>Niet meedenken in</span>
        <span class="chips">
          {#each Object.entries(prefs.thinkAlongMuted) as [id, name] (id)}
            <button class="chip" title="Weer meedenken" onclick={() => unmute(id)}>{name} ✕</button>
          {/each}
        </span>
      </div>
    {/if}
    {#if s.shortcuts.lookAlong}
      <p class="faint note">Meekijken: druk {s.shortcuts.lookAlong} en Nook leest het voorste venster en stelt iets voor als er een afspraak, belofte of taak in staat.</p>
    {/if}
  </div>
{/if}

{#if prefs && caps?.screenPart}
  <h3>Schermdeel</h3>
  <div class="group">
    <label class="row">
      <span>Sneltoets<br /><small class="faint">Trek een kader om een stuk van je scherm; dat gaat als afbeelding naar de chat.</small></span>
      <input value={prefs.screenPartShortcut} onchange={(e) => save({ screenPartShortcut: e.currentTarget.value })} />
    </label>
    <div class="row"><span>Nu een schermdeel</span><button onclick={() => services.partBegin()}>Kader trekken</button></div>
  </div>
{/if}

<style>
  small { font-size: 11px; line-height: 1.35; display: inline-block; max-width: 460px; }
  .now { max-width: 340px; text-align: right; font-size: 12px; }
  .chips { display: flex; gap: 6px; flex-wrap: wrap; justify-content: flex-end; }
  .chip { font-size: 11px; padding: 2px 8px; border-radius: 999px; }
</style>
