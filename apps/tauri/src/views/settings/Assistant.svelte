<script lang="ts">
  import { tip } from "../../components/ui/tip";
  import { accessOf, type NookAccess } from "../../lib/access";
  // Assistent: wat Nook ziet (je schermen, het klembord, je bestanden, je gesprekken), of hij meedenkt,
  // wat hij zelf mag, Dubbeltik (UI-80) en Nook als maatje (UI-21).
  import { nook } from "../../lib/state.svelte";
  import { tr, appLanguage } from "../../lib/i18n.svelte";
  import { buddy } from "../../lib/buddy.svelte";
  import Orb from "../../components/Orb.svelte";
  import Segmented from "./Segmented.svelte";
  import LinkRow from "./LinkRow.svelte";
  import Fold from "./Fold.svelte";
  import { readableShortcut } from "../../lib/accelerator";
  import { services, screenLine, type EnergyView, type ServicePrefs, type ScreenStatus } from "../../lib/services";

  const s = $derived(nook.settings!);
  const caps = $derived(nook.info?.capabilities);
  let prefs = $state<ServicePrefs | null>(null);
  let screen = $state<ScreenStatus | null>(null);
  let energy = $state<EnergyView | null>(null);

  // Double Tap settings (UI-80), persisted in localStorage so they work immediately without modifying core Settings.
  type DoubleTapKey = "ctrl" | "alt" | "shift";
  let doubleTapEnabled = $state<boolean>((typeof localStorage !== "undefined" && localStorage.getItem("nook.doubleTap.enabled") !== "false"));
  let doubleTapKey = $state<DoubleTapKey>((typeof localStorage !== "undefined" ? (localStorage.getItem("nook.doubleTap.key") as DoubleTapKey) : null) || "ctrl");
  let doubleTapTakeover = $state<boolean>(typeof localStorage !== "undefined" ? localStorage.getItem("nook.doubleTap.takeover") === "true" : false);
  let doubleTapOneClick = $state<boolean>(typeof localStorage !== "undefined" ? localStorage.getItem("nook.doubleTap.oneClick") !== "false" : true);

  function saveDoubleTap(patch: Partial<{ enabled: boolean; key: DoubleTapKey; takeover: boolean; oneClick: boolean }>) {
    if (patch.enabled !== undefined) {
      doubleTapEnabled = patch.enabled;
      if (typeof localStorage !== "undefined") localStorage.setItem("nook.doubleTap.enabled", String(patch.enabled));
    }
    if (patch.key !== undefined) {
      doubleTapKey = patch.key;
      if (typeof localStorage !== "undefined") localStorage.setItem("nook.doubleTap.key", patch.key);
    }
    if (patch.takeover !== undefined) {
      doubleTapTakeover = patch.takeover;
      if (typeof localStorage !== "undefined") localStorage.setItem("nook.doubleTap.takeover", String(patch.takeover));
    }
    if (patch.oneClick !== undefined) {
      doubleTapOneClick = patch.oneClick;
      if (typeof localStorage !== "undefined") localStorage.setItem("nook.doubleTap.oneClick", String(patch.oneClick));
    }
  }

  // Buddy moments (UI-21)
  const moments = $derived(s.buddyMoments !== false);
  const tone = $derived<"calm" | "warm" | "playful">(s.buddyTone ?? "warm");
  const sampleLine = $derived(
    tone === "calm" ? tr("Goedemorgen. Je hebt vandaag {n} afspraken.", "Good morning. {n} events in your calendar today.", { n: 3 })
      : tone === "playful" ? tr("Goeiemorgen, zonnetje! {n} afspraken vandaag. Eerst koffie?", "Morning, sunshine! {n} events today. Coffee first?", { n: 3 })
      : tr("Morgen! Je hebt vandaag {n} dingen op de planning.", "Morning! You have {n} things on today.", { n: 3 }),
  );
  const bday = $derived.by(() => {
    const [m, d] = (s.birthday ?? "").split("-").map((x) => Number(x) || 0);
    return { month: m ?? 0, day: d ?? 0 };
  });
  const pad = (n: number) => String(n).padStart(2, "0");
  function setBirthday(part: Partial<{ month: number; day: number }>) {
    const next = { ...bday, ...part };
    nook.saveSettings({ birthday: next.month === 0 && next.day === 0 ? "" : `${pad(next.month)}-${pad(next.day)}` });
  }
  const monthNames = $derived.by(() => {
    const format = new Intl.DateTimeFormat(appLanguage(), { month: "long" });
    return Array.from({ length: 12 }, (_, i) => {
      const name = format.format(new Date(2000, i, 1));
      return name.charAt(0).toUpperCase() + name.slice(1);
    });
  });

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

<!-- The Mac's Assistant (`assistantSection`): what Nook sees, its proactive suggestions, what it may do, Double Tap, and Buddy moments. -->
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
  <LinkRow icon="brain" title={tr("Geheugen beheren", "Manage memory")} to="memory" />
  <LinkRow icon="hand" title={tr("Beheer machtigingen bij Privacy en toegang", "Manage permissions under Privacy & access")} to="permissions" />
</div>

<h3>{tr("Meedenken", "Proactive suggestions")}</h3>
<div class="group">
  <label class="row">
    <span>{tr("Vraag over geselecteerde tekst", "Ask about selected text")}<br /><small>{tr("Selecteer woorden waar dan ook in Nook (een bericht, een antwoord, een pull request) en een kleine balk erboven beantwoordt, legt uit of vertaalt ze meteen, zonder de chat te openen.", "Select words anywhere in Nook (a message, an answer, a pull request) and a small bar above them answers, explains or translates them right there, without opening the chat.")}</small></span>
    <input type="checkbox" role="switch" checked={s.selectionAsk !== false} onchange={(e) => nook.saveSettings({ selectionAsk: e.currentTarget.checked })} />
  </label>
  <label class="row">
    <span>{tr("Zoek op het web als dat nodig is", "Search the web when needed")}<br /><small>{tr("Voor nieuws, weer, uitslagen, prijzen en openingstijden.", "For news, weather, scores, prices, and opening hours.")}</small></span>
    <input type="checkbox" role="switch" checked={s.webSearch} onchange={(e) => nook.saveSettings({ webSearch: e.currentTarget.checked })} />
  </label>
  {#if caps?.screenReading}
    <label class="row" class:dim={Boolean(nook.info?.brainLocal)}>
      <span>{tr("Denk mee terwijl ik werk", "Suggest ideas while I work")}<br /><small>{tr("Nook stelt naast de balk voor wat het kan overnemen of slimmer kan, en houdt zich in als je vaak nee zegt. Leest af en toe het voorste venster.", "Nook proposes next to the bar what it can take over or do smarter, and holds back if you often say no. Reads the front window now and then.")}</small></span>
      <input type="checkbox" role="switch" checked={s.autoWatch && !nook.info?.brainLocal} disabled={Boolean(nook.info?.brainLocal)} onchange={(e) => nook.saveSettings({ autoWatch: e.currentTarget.checked })} />
    </label>
    {#if nook.info?.brainLocal}
      <p class="note">{tr("Meedenken terwijl je werkt gebruikt een online brein; met een lokaal brein blijft het uit om je processor en accu rustig te houden.", "Proactive suggestions while you work use an online brain; with a local brain this stays off to keep your processor and battery quiet.")}</p>
      <LinkRow icon="cpu" title={tr("Kies een brein bij Brein", "Choose a brain under Brain")} to="brain" />
    {/if}
    {#if prefs && Object.keys(prefs.thinkAlongMuted).length}
      <div class="row">
        <span>{tr("Niet meedenken in", "Don't think along in")}</span>
        <span class="chips">
          {#each Object.entries(prefs.thinkAlongMuted) as [id, name] (id)}
            <button class="chip" use:tip={tr("Weer meedenken", "Think along again")} onclick={() => unmute(id)}>{name} ✕</button>
          {/each}
        </span>
      </div>
    {/if}
    {#if s.shortcuts.lookAlong}
      <p class="note">{tr("Meekijken: druk {keys} en Nook leest het voorste venster en stelt iets voor als er een afspraak, belofte of taak in staat.", "Look along: press {keys} and Nook reads the front window and suggests something if it holds an appointment, promise or task.", { keys: readableShortcut(s.shortcuts.lookAlong) })}</p>
    {/if}
  {/if}
</div>

<!-- Double Tap (UI-80): tap a modifier key twice to ask about or act on the front window. -->
<h3>{tr("Dubbeltik", "Double Tap")}</h3>
<div class="group">
  <label class="row">
    <span>{tr("Dubbeltik inschakelen", "Enable Double Tap")}<br /><small>{tr("Tik twee keer snel op een modificatietoets om Nook meteen bij het actieve venster te roepen.", "Tap a modifier key twice quickly to summon Nook right at the active window.")}</small></span>
    <input type="checkbox" role="switch" checked={doubleTapEnabled} onchange={(e) => saveDoubleTap({ enabled: e.currentTarget.checked })} />
  </label>
  <div class="row" class:dim={!doubleTapEnabled}>
    <span>{tr("Modificatietoets", "Modifier key")}</span>
    <Segmented label={tr("Modificatietoets", "Modifier key")} value={doubleTapKey} onchange={(v) => doubleTapEnabled && saveDoubleTap({ key: v as DoubleTapKey })}
      options={[{ value: "ctrl", label: "Ctrl · Ctrl" }, { value: "alt", label: "Alt · Alt" }, { value: "shift", label: "Shift · Shift" }]} />
  </div>
  <label class="row" class:dim={!doubleTapEnabled}>
    <span>{tr("Scherm direct overnemen bij dubbeltik", "Take over on tap")}<br /><small>{tr("Nook kijkt meteen naar het venster onder je aanwijzer en bereidt de volgende stap voor.", "Nook immediately looks at the window under your pointer and prepares the next step.")}</small></span>
    <input type="checkbox" role="switch" checked={doubleTapTakeover} disabled={!doubleTapEnabled} onchange={(e) => saveDoubleTap({ takeover: e.currentTarget.checked })} />
  </label>
  <label class="row" class:dim={!doubleTapEnabled}>
    <span>{tr("Voorstellen met één klik uitvoeren", "One-click suggestions")}<br /><small>{tr("Toon directe actieknoppen naast je cursor zodat één klik genoeg is.", "Show direct action buttons beside your cursor so a single click is enough.")}</small></span>
    <input type="checkbox" role="switch" checked={doubleTapOneClick} disabled={!doubleTapEnabled} onchange={(e) => saveDoubleTap({ oneClick: e.currentTarget.checked })} />
  </label>
</div>

<!-- The same choice as under the message field (⇧Tab there), as one segmented control + foldable capabilities list. -->
<h3>{tr("Wat Nook zelf mag", "What Nook may do")}</h3>
<div class="group">
  <div class="row access">
    <Segmented label={tr("Wat Nook zelf mag", "What Nook may do")} value={accessOf(s)} onchange={(v) => nook.saveSettings({ nookAccess: v as NookAccess })}
      options={[{ value: "ask", label: tr("Vragen", "Ask") }, { value: "small", label: tr("Klein", "Small things") }, { value: "more", label: tr("Handelen", "Act") }]} />
  </div>
  <p class="note">{accessDetail(accessOf(s))} {tr("Mail, berichten, links, opdrachten, instellingen en verwijderen vragen altijd eerst.", "Mail, messages, links, commands, settings, and deleting always ask first.")}</p>
</div>

<Fold keys={[tr("Vragen", "Ask"), tr("Klein", "Small things"), tr("Handelen", "Act")]} title={tr("Wat valt onder welk niveau", "What each level covers")} summary={tr("Overzicht van acties per niveau", "Overview of actions per level")}>
  <div class="row">
    <span><strong>{tr("Vragen", "Ask")}</strong><br /><small>{tr("Lezen en opzoeken mag direct; elke verandering wacht tot je op Uitvoeren klikt.", "Reading and looking up happen right away; every change waits until you click Run.")}</small></span>
  </div>
  <div class="row">
    <span><strong>{tr("Klein", "Small things")}</strong><br /><small>{tr("Muziek afspelen of pauzeren, volume aanpassen, een app openen, een herinnering of taak op je lijst zetten.", "Play or pause music, adjust volume, open an app, add a reminder or a to-do item.")}</small></span>
  </div>
  <div class="row">
    <span><strong>{tr("Handelen", "Act")}</strong><br /><small>{tr("Ook een afspraak zonder gasten in je agenda zetten, een herinnering afvinken en een notitie bewaren. Berichten sturen, betalen of verwijderen vraagt altijd eerst.", "Also schedule a calendar event without guests, complete a reminder, and save a note. Sending messages, paying, or deleting always asks first.")}</small></span>
  </div>
</Fold>

<h3>{tr("Nook als maatje", "Nook as a buddy")}</h3>
<div class="group">
  <label class="row">
    <span>{tr("Kleine momenten", "Little moments")}<br /><small>{tr("Goedemorgen, welkom terug, af en toe een pauze, mijlpalen. Hooguit vier keer per dag, nooit in een vergadering.", "Good morning, welcome back, a break now and then, milestones. At most four times a day, never in a meeting.")}</small></span>
    <input type="checkbox" role="switch" checked={moments} onchange={(e) => nook.saveSettings({ buddyMoments: e.currentTarget.checked })} />
  </label>
  <div class="row" class:dim={!moments}>
    <span>{tr("Toon", "Tone")}</span>
    <Segmented label={tr("Toon", "Tone")} value={tone} onchange={(v) => moments && nook.saveSettings({ buddyTone: v })}
      options={[{ value: "calm", label: tr("Rustig", "Calm") }, { value: "warm", label: tr("Warm", "Warm") }, { value: "playful", label: tr("Speels", "Playful") }]} />
  </div>
  <div class="row sample" class:dim={!moments}>
    <span class="sample-face"><Orb size={26} mood="cozy" /></span>
    <span class="sample-line">{sampleLine}</span>
  </div>
  <div class="row">
    <span>{tr("Je verjaardag", "Your birthday")}</span>
    <span class="birthday">
      <select aria-label={tr("Dag", "Day")} value={bday.day} onchange={(e) => setBirthday({ day: Number(e.currentTarget.value) })}>
        <option value={0}>–</option>
        {#each Array.from({ length: 31 }, (_, i) => i + 1) as d (d)}<option value={d}>{d}</option>{/each}
      </select>
      <select aria-label={tr("Maand", "Month")} value={bday.month} onchange={(e) => setBirthday({ month: Number(e.currentTarget.value) })}>
        <option value={0}>–</option>
        {#each monthNames as name, i (i)}<option value={i + 1}>{name}</option>{/each}
      </select>
    </span>
  </div>
  <div class="row">
    <button class="capsule" onclick={() => buddy.requestBreathe()}>{tr("Nu even ademen met Nook", "Breathe with Nook now")}</button>
  </div>
</div>

<style>
  small { font: var(--text-detail); line-height: 1.3; display: inline-block; }
  .now { max-width: 340px; text-align: right; color: var(--text2); }
  /* The Mac draws this segmented picker at its own width, on the left of its row. */
  .access { justify-content: flex-start; }
  .chips { display: flex; gap: 6px; flex-wrap: wrap; justify-content: flex-end; }
  .chip { font: var(--text-label); padding: 2px 8px; border-radius: var(--radius-pill); }
  .dim { opacity: 0.45; }
  .sample { justify-content: flex-start; gap: var(--space-sm); }
  .sample-face { display: inline-flex; align-items: center; }
  .sample-line { font: var(--text-label); color: var(--text2); font-style: italic; }
  .birthday { display: inline-flex; gap: 6px; }
</style>
