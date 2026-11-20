<script lang="ts">
  import { accessOf, type NookAccess } from "../../lib/access";
  // Assistent: wat Nook ziet (je schermen, het klembord, je bestanden, je gesprekken) en of hij meedenkt.
  import { nook } from "../../lib/state.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import Segmented from "./Segmented.svelte";
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

  function accessDetail(level: NookAccess) {
    return level === "ask"
      ? tr("Elke actie wacht op je klik.", "Every action waits for your click.")
      : level === "small"
        ? tr("Muziek, volume, een app, een herinnering of een open punt gebeuren meteen als je erom vraagt.", "Music, volume, an app, a reminder, or a to-do happen at once when you ask for them.")
        : tr("Ook een afspraak zonder genodigden maken, een herinnering afvinken en een notitie. Een afspraak aanpassen, of een stap die betaalt, bestelt, verstuurt, verwijdert of boekt, vraagt nog steeds eerst.", "Also adding a calendar event without guests, ticking off a reminder, and a note. Changing an event, or a step that pays, orders, sends, deletes, or books, still asks first.");
  }

  function unmute(id: string) {
    if (!prefs) return;
    const muted = { ...prefs.thinkAlongMuted };
    delete muted[id];
    save({ thinkAlongMuted: muted });
  }
</script>


<!-- The Mac's Assistant (`assistantSection`): what Nook sees, its proactive suggestions, and what it may do. The
     clipboard, files and calls are Windows' own sources and stay with what Nook sees; the screen area shortcut is under
     Shortcuts, as on the Mac. -->
<h3>{tr("Wat Nook ziet", "What Nook sees")}</h3>
<div class="group">
  {#if caps?.screenReading}
    <label class="row">
      <span>{tr("Houd al mijn schermen bij", "Track all my screens")}<br /><small>{tr("Nook leest de tekst van al je vensters op al je schermen, op je computer. Daardoor is een antwoord direct klaar.", "Nook reads text from all windows across all screens, locally on your computer. Replies are instantly ready.")}</small></span>
      <input type="checkbox" role="switch" checked={s.liveScreen} onchange={(e) => nook.saveSettings({ liveScreen: e.currentTarget.checked })} />
    </label>
    <label class="row">
      <span>{tr("Gebruik mijn schermen bij elke vraag", "Use my screens with every question")}<br /><small>{tr("Uit: alleen als je naar iets verwijst (\"dit\", \"hier\", \"die mail\").", "Off: only when you refer to something (\"this\", \"here\", \"that email\").")}</small></span>
      <input type="checkbox" role="switch" checked={s.screenWithEveryQuestion} onchange={(e) => nook.saveSettings({ screenWithEveryQuestion: e.currentTarget.checked })} />
    </label>
    <div class="row">
      <span>{tr("Nu in beeld", "Currently in view")}</span>
      <span class="now">{screenLine(s.liveScreen || s.autoWatch, screen?.windows ?? [], energy)}</span>
    </div>
    {#if screen?.status}<p class="note">{screen.status}</p>{/if}
  {:else}
    <p class="note">{caps?.notes?.screenReading ?? tr("Op dit apparaat kan Nook niet meekijken.", "Nook can't look along on this device.")}</p>
  {/if}
  {#if prefs && caps?.clipboard}
    <label class="row">
      <span>{tr("Klembord", "Clipboard")}<br /><small>{tr("Wat je net kopieerde. Wachtwoorden die een wachtwoordbeheerder als geheim markeert, slaat Nook altijd over.", "What you just copied. Nook always skips passwords a password manager marks as secret.")}</small></span>
      <input type="checkbox" role="switch" checked={prefs.clipboard} onchange={(e) => save({ clipboard: e.currentTarget.checked })} />
    </label>
  {/if}
  {#if prefs && caps?.files}
    <label class="row">
      <span>{tr("Bestanden", "Files")}<br /><small>{tr("Zoeken en lezen in je thuismap, nooit in verborgen mappen, sleutels of wachtwoordexports.", "Search and read in your home folder, never in hidden folders, keys or password exports.")}</small></span>
      <input type="checkbox" role="switch" checked={prefs.files} onchange={(e) => save({ files: e.currentTarget.checked })} />
    </label>
  {/if}
  {#if prefs}
    <label class="row">
      <span>{tr("Gesprekken", "Calls")}<br /><small>{tr("Wat de Notetaker noteerde, doorzoekbaar in de chat. Alleen op deze computer.", "What the Notetaker wrote down, searchable in the chat. Only on this computer.")}</small></span>
      <input type="checkbox" role="switch" checked={prefs.callNotes} onchange={(e) => save({ callNotes: e.currentTarget.checked })} />
    </label>
  {/if}
</div>

<h3>{tr("Meedenken", "Proactive suggestions")}</h3>
<div class="group">
  <label class="row">
    <span>{tr("Vraag over geselecteerde tekst", "Ask about selected text")}<br /><small>{tr("Selecteer woorden waar dan ook in Nook (een bericht, een antwoord, een pull request) en een kleine balk erboven beantwoordt, legt uit of vertaalt ze meteen, zonder de chat te openen.", "Select words anywhere in Nook (a message, an answer, a pull request) and a small bar above them answers, explains or translates them right there, without opening the chat.")}</small></span>
    <input type="checkbox" role="switch" checked={s.selectionAsk !== false} onchange={(e) => nook.saveSettings({ selectionAsk: e.currentTarget.checked })} />
  </label>
  {#if s.provider === "claude"}
    <label class="row">
      <span>{tr("Zoek op het web als dat nodig is", "Search the web when needed")}<br /><small>{tr("Voor nieuws, weer, uitslagen, prijzen en openingstijden.", "For news, weather, scores, prices, and opening hours.")}</small></span>
      <input type="checkbox" role="switch" checked={s.webSearch} onchange={(e) => nook.saveSettings({ webSearch: e.currentTarget.checked })} />
    </label>
  {/if}
  {#if caps?.screenReading}
    <label class="row">
      <span>{tr("Denk mee terwijl ik werk", "Suggest ideas while I work")}<br /><small>{tr("Kan Nook iets overnemen of weet hij een slimmere aanpak, dan stelt hij het voor naast de balk. Zeg je vaker nee, dan houdt hij zich in. Stuurt af en toe de tekst van je voorste vensters naar je brein.", "If Nook can take something over or knows a smarter approach, it suggests it next to the bar. Say no more often and it holds back. Now and then it sends the text of your front windows to your brain.")}</small></span>
      <input type="checkbox" role="switch" checked={s.autoWatch} onchange={(e) => nook.saveSettings({ autoWatch: e.currentTarget.checked })} />
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
      <p class="note">{tr("Meekijken: druk {keys} en Nook leest het voorste venster en stelt iets voor als er een afspraak, belofte of taak in staat.", "Look along: press {keys} and Nook reads the front window and suggests something if it holds an appointment, promise or task.", { keys: s.shortcuts.lookAlong })}</p>
    {/if}
  {/if}
</div>

<!-- The same choice as under the message field (⇧Tab there), as one segmented control. -->
<h3>{tr("Wat Nook zelf mag", "What Nook may do")}</h3>
<div class="group">
  <div class="row access">
    <Segmented label={tr("Wat Nook zelf mag", "What Nook may do")} value={accessOf(s)} onchange={(v) => nook.saveSettings({ nookAccess: v as NookAccess })}
      options={[{ value: "ask", label: tr("Vragen", "Ask") }, { value: "small", label: tr("Klein", "Small things") }, { value: "more", label: tr("Meer", "More") }]} />
  </div>
  <p class="note">{accessDetail(accessOf(s))} {tr("Mail, berichten, links, opdrachten, instellingen en verwijderen vragen altijd eerst.", "Mail, messages, links, commands, settings, and deleting always ask first.")}</p>
</div>

<style>
  small { font: var(--text-detail); line-height: 1.3; display: inline-block; }
  .now { max-width: 340px; text-align: right; color: var(--text2); }
  /* The Mac draws this segmented picker at its own width, on the left of its row. */
  .access { justify-content: flex-start; }
  .chips { display: flex; gap: 6px; flex-wrap: wrap; justify-content: flex-end; }
  .chip { font: var(--text-label); padding: 2px 8px; border-radius: var(--radius-pill); }
</style>
