<script lang="ts">
  // Assistent: wat Nook ziet (je schermen, het klembord, je bestanden, je gesprekken) en of hij meedenkt.
  import { nook } from "../../lib/state.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import { services, screenLine, type EnergyView, type ServicePrefs, type ScreenStatus } from "../../lib/services";

  const s = $derived(nook.settings!);
  const caps = $derived(nook.info?.capabilities);
  let prefs = $state<ServicePrefs | null>(null);
  let screen = $state<ScreenStatus | null>(null);
  let energy = $state<EnergyView | null>(null);

  $effect(() => {
    services.prefs().then((p) => (prefs = p));
    const read = () => {
      services.screenStatus().then((st) => (screen = st));
      services.energyStatus().then((v) => (energy = v)).catch(() => {});
    };
    read();
    const timer = setInterval(read, 8000);
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

<h2>{tr("Assistent", "Assistant")}</h2>

<h3>{tr("Wat Nook ziet", "What Nook sees")}</h3>
<div class="group">
  {#if caps?.screenReading}
    <label class="row">
      <span>{tr("Houd al mijn schermen bij", "Keep track of all my screens")}<br /><small class="faint">{tr("Nook leest de tekst van al je vensters, op deze computer. Daardoor is een antwoord direct klaar.", "Nook reads the text of all your windows, on this computer. That way an answer is ready right away.")}</small></span>
      <input type="checkbox" checked={s.liveScreen} onchange={(e) => nook.saveSettings({ liveScreen: e.currentTarget.checked })} />
    </label>
    <label class="row">
      <span>{tr("Gebruik mijn schermen bij elke vraag", "Use my screens with every question")}<br /><small class="faint">{tr("Uit: alleen als je naar iets verwijst (\"dit\", \"hier\", \"die mail\").", "Off: only when you refer to something (\"this\", \"here\", \"that email\").")}</small></span>
      <input type="checkbox" checked={s.screenWithEveryQuestion} onchange={(e) => nook.saveSettings({ screenWithEveryQuestion: e.currentTarget.checked })} />
    </label>
    <div class="row">
      <span>{tr("Nu in beeld", "On screen now")}</span>
      <span class="faint now">{screenLine(s.liveScreen || s.autoWatch, screen?.windows ?? [], energy)}</span>
    </div>
    {#if screen?.status}<p class="faint note">{screen.status}</p>{/if}
  {:else}
    <p class="faint note">{caps?.notes?.screenReading ?? tr("Op dit apparaat kan Nook niet meekijken.", "Nook can't look along on this device.")}</p>
  {/if}
  {#if prefs && caps?.clipboard}
    <label class="row">
      <span>{tr("Klembord", "Clipboard")}<br /><small class="faint">{tr("Wat je net kopieerde. Wachtwoorden die een wachtwoordbeheerder als geheim markeert, slaat Nook altijd over.", "What you just copied. Nook always skips passwords a password manager marks as secret.")}</small></span>
      <input type="checkbox" checked={prefs.clipboard} onchange={(e) => save({ clipboard: e.currentTarget.checked })} />
    </label>
  {/if}
  {#if prefs && caps?.files}
    <label class="row">
      <span>{tr("Bestanden", "Files")}<br /><small class="faint">{tr("Zoeken en lezen in je thuismap, nooit in verborgen mappen, sleutels of wachtwoordexports.", "Search and read in your home folder, never in hidden folders, keys or password exports.")}</small></span>
      <input type="checkbox" checked={prefs.files} onchange={(e) => save({ files: e.currentTarget.checked })} />
    </label>
  {/if}
  {#if prefs}
    <label class="row">
      <span>{tr("Gesprekken", "Calls")}<br /><small class="faint">{tr("Wat de Notetaker noteerde, doorzoekbaar in de chat. Alleen op deze computer.", "What the Notetaker wrote down, searchable in the chat. Only on this computer.")}</small></span>
      <input type="checkbox" checked={prefs.callNotes} onchange={(e) => save({ callNotes: e.currentTarget.checked })} />
    </label>
  {/if}
</div>

{#if caps?.screenReading}
  <h3>{tr("Meedenken", "Think along")}</h3>
  <div class="group">
    <label class="row">
      <span>{tr("Denk mee terwijl ik werk", "Think along while I work")}<br /><small class="faint">{tr("Kan Nook iets overnemen of weet hij een slimmere aanpak, dan stelt hij het voor naast de balk. Zeg je vaker nee, dan houdt hij zich in. Stuurt af en toe de tekst van je voorste vensters naar je brein.", "If Nook can take something over or knows a smarter approach, it suggests it next to the bar. Say no more often and it holds back. Now and then it sends the text of your front windows to your brain.")}</small></span>
      <input type="checkbox" checked={s.autoWatch} onchange={(e) => nook.saveSettings({ autoWatch: e.currentTarget.checked })} />
    </label>
    <label class="row">
      <span>{tr("Kleine dingen meteen doen", "Do small things right away")}<br /><small class="faint">{tr("Muziek, volume, een app, een herinnering of een open punt. Afspraken, mail, links, opdrachten en diensten vragen altijd eerst.", "Music, volume, an app, a reminder or an open item. Appointments, mail, links, commands and services always ask first.")}</small></span>
      <input type="checkbox" checked={s.autoRunSafe} onchange={(e) => nook.saveSettings({ autoRunSafe: e.currentTarget.checked })} />
    </label>
    {#if prefs && Object.keys(prefs.thinkAlongMuted).length}
      <div class="row">
        <span>{tr("Niet meedenken in", "Don't think along in")}</span>
        <span class="chips">
          {#each Object.entries(prefs.thinkAlongMuted) as [id, name] (id)}
            <button class="chip" title={tr("Weer meedenken", "Think along again")} onclick={() => unmute(id)}>{name} ✕</button>
          {/each}
        </span>
      </div>
    {/if}
    {#if s.shortcuts.lookAlong}
      <p class="faint note">{tr("Meekijken: druk {keys} en Nook leest het voorste venster en stelt iets voor als er een afspraak, belofte of taak in staat.", "Look along: press {keys} and Nook reads the front window and suggests something if it holds an appointment, promise or task.", { keys: s.shortcuts.lookAlong })}</p>
    {/if}
  </div>
{/if}

{#if prefs && caps?.screenPart}
  <h3>{tr("Schermdeel", "Screen area")}</h3>
  <div class="group">
    <label class="row">
      <span>{tr("Sneltoets", "Shortcut")}<br /><small class="faint">{tr("Trek een kader om een stuk van je scherm; dat gaat als afbeelding naar de chat.", "Draw a frame around part of your screen; it goes to the chat as an image.")}</small></span>
      <input value={prefs.screenPartShortcut} onchange={(e) => save({ screenPartShortcut: e.currentTarget.value })} />
    </label>
    <div class="row"><span>{tr("Nu een schermdeel", "Capture a screen area now")}</span><button onclick={() => services.partBegin()}>{tr("Kader trekken", "Draw a frame")}</button></div>
  </div>
{/if}

<style>
  small { font-size: 11px; line-height: 1.35; display: inline-block; max-width: 460px; }
  .now { max-width: 340px; text-align: right; font-size: 12px; }
  .chips { display: flex; gap: 6px; flex-wrap: wrap; justify-content: flex-end; }
  .chip { font-size: 11px; padding: 2px 8px; border-radius: 999px; }
</style>
