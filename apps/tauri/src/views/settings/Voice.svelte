<script lang="ts">
  // Voice, sound and the bar's quiet behaviour, shown one part at a time where the Mac has them: Notifications › Sound
  // & voice (talking and reading aloud, "Hey Nook", the Notetaker, sounds, also your own), Notifications (how big a
  // notice is), Typing › Dictation (speech recognition, dictating anywhere with Flow) and General › Bar & windows (how
  // Nook behaves in meetings and while you share your screen).
  let { part }: { part: "sound" | "notices" | "dictation" | "quiet" } = $props();
  import { nook } from "../../lib/state.svelte";
  import { services, type FlowView, type ServicePrefs, type VoiceInfo, type SpeechEngine, type FlowSettings, type QuietView } from "../../lib/services";
  import type { QuietBehavior } from "../../lib/types";
  import { playChoice, forgetCustomSounds, type SoundName } from "../../lib/sounds";
  import IconButton from "../../components/ui/IconButton.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import { tr } from "../../lib/i18n.svelte";

  const s = $derived(nook.settings!);

  // Settings › Notifications: the agents' style is `agentNotice` (detailed = card, compact = one line); the other
  // sources and the quiet hours are in `noticeRules` (`nook_core::services::notice_rules`).
  type NoticeStyle = "card" | "strip" | "system" | "off";
  type Rules = NonNullable<typeof s.noticeRules>;
  const HOURS = Array.from({ length: 24 }, (_, i) => i);
  const rules = $derived<Rules>(s.noticeRules ?? { styles: {}, apps: {}, quietHours: null, quietWhileWatching: false });
  const sources = $derived([
    { id: "agents", title: tr("Agents", "Agents"), detail: tr("Een coding agent in een terminal of in Nook is klaar, loopt vast of wacht op je.", "A coding agent in a terminal or in Nook is done, failed or waits on you.") },
    { id: "chats", title: tr("Chatberichten", "Chat messages"), detail: tr("Een nieuw bericht in WhatsApp of een andere chat-app.", "A new message in WhatsApp or another chat app.") },
    { id: "nook", title: "Nook", detail: tr("Een antwoord dat klaar is terwijl je ergens anders keek, gespreksnotities die klaarstaan.", "An answer that finished while you looked elsewhere, call notes that are ready.") },
    { id: "suggestions", title: tr("Meedenken", "Think Along"), detail: tr("Een voorstel over wat er op je scherm staat.", "An offer about what is on your screen.") },
  ]);
  const styleChoices = $derived<{ id: NoticeStyle; title: string }[]>([
    { id: "card", title: tr("Kaart", "Card") }, { id: "strip", title: tr("Eén regel", "One line") },
    { id: "system", title: tr("Systeemmelding", "System notification") }, { id: "off", title: tr("Niet tonen", "Don't show") },
  ]);
  const AGENT_STYLE: Record<string, NoticeStyle> = { detailed: "card", compact: "strip", system: "system", off: "off" };
  const AGENT_NOTICE: Record<NoticeStyle, "detailed" | "compact" | "system" | "off"> = { card: "detailed", strip: "compact", system: "system", off: "off" };
  function styleOf(id: string): NoticeStyle {
    if (id === "agents") return AGENT_STYLE[s.agentNotice ?? "detailed"] ?? "card";
    return rules.styles[id] ?? (id === "suggestions" ? "strip" : "card");
  }
  function setStyle(id: string, style: NoticeStyle) {
    if (id === "agents") nook.saveSettings({ agentNotice: AGENT_NOTICE[style] });
    else setRules({ styles: { ...rules.styles, [id]: style } });
  }
  function setRules(patch: Partial<Rules>) {
    nook.saveSettings({ noticeRules: { ...rules, ...patch } });
  }
  const caps = $derived(nook.info?.capabilities);
  let prefs = $state<ServicePrefs | null>(null);
  let info = $state<VoiceInfo | null>(null);
  let flow = $state<FlowView | null>(null);
  let dictionary = $state("");
  let folder = $state<string | null>(null);
  let message = $state<string | null>(null);

  const load = async () => {
    [prefs, info, flow] = await Promise.all([services.prefs(), services.voiceInfo(), services.flowView()]);
    dictionary = flow.dictionary;
  };
  $effect(() => {
    load();
  });

  async function save(patch: Partial<ServicePrefs>) {
    if (!prefs) return;
    prefs = await services.savePrefs({ ...prefs, ...patch });
    info = await services.voiceInfo();
  }

  // Meetings and screen sharing. While this page is open Nook reads the situation, also with "change nothing" for both.
  const behaviors: { id: QuietBehavior; title: string }[] = $derived([
    { id: "normal", title: tr("Niets veranderen", "Change nothing") },
    { id: "quiet", title: tr("Stil: geen meldingen of geluiden", "Quiet: no notifications or sounds") },
    { id: "hideFromShare", title: tr("Verbergen voor kijkers (jij ziet Nook nog)", "Hide from viewers (you still see Nook)") },
    { id: "hide", title: tr("Helemaal verbergen, ook voor jou", "Hide completely, also for you") },
  ]);
  const meetingBehaviors = $derived(behaviors.filter((b) => b.id !== "hideFromShare"));
  let quietNow = $state<QuietView | null>(null);
  $effect(() => {
    if (!caps?.desktop) return;
    const read = () => services.quietStatus(true).then((v) => (quietNow = v)).catch(() => {});
    read();
    const timer = setInterval(read, 2000);
    return () => clearInterval(timer);
  });

  async function saveFlow(patch: Partial<FlowSettings>) {
    if (!flow) return;
    await services.saveFlowSettings({ ...flow.settings, ...patch });
    flow = await services.flowView();
  }

  const engines: { id: SpeechEngine; title: string; detail: string; when?: () => boolean }[] = $derived([
    { id: "local", title: tr("Op deze computer (whisper.cpp)", "On this computer (whisper.cpp)"), detail: tr("Niets gaat naar buiten. Vraagt het programma whisper-cli en een model.", "Nothing leaves your computer. Needs the whisper-cli program and a model.") },
    { id: "windows", title: tr("Spraakherkenning van Windows", "Windows speech recognition"), detail: tr("Vrije tekst gaat via de online spraakherkenning van Microsoft. Alleen praten en Flow.", "Free text goes through Microsoft's online speech recognition. Only talking and Flow."), when: () => caps?.os === "windows" },
    { id: "openai", title: "OpenAI", detail: tr("Je opname gaat naar {service}, met je eigen sleutel (Instellingen › Brein).", "Your recording goes to {service}, with your own key (Settings › Brain).", { service: "OpenAI" }) },
    { id: "groq", title: "Groq", detail: tr("Je opname gaat naar {service}, met je eigen sleutel (Instellingen › Brein).", "Your recording goes to {service}, with your own key (Settings › Brain).", { service: "Groq" }) },
  ]);

  // Nooit stilletjes naar de cloud: een externe herkenning kies je pas na een tweede klik.
  let pending = $state<SpeechEngine | null>(null);
  async function choose(id: SpeechEngine) {
    if (id !== "local" && pending !== id) {
      pending = id;
      // De keuze staat pas na de bevestiging: het rondje terug naar wat er was.
      if (prefs) prefs = { ...prefs };
      return;
    }
    pending = null;
    await save({ speechEngine: id });
  }

  // Each moment's sound (`NookSound` on the Mac; Windows plays one sound for a question and a permission request).
  const moments = $derived<{ id: SoundName; title: string }[]>([
    { id: "done", title: tr("Agent is klaar", "Agent is done") },
    { id: "attention", title: tr("Agent stelt een vraag of wacht op je", "Agent asks a question or waits on you") },
    { id: "error", title: tr("Agent stopt met een fout", "Agent stops with an error") },
  ]);
  let soundList = $state<{ system: string[]; custom: string[] }>({ system: [], custom: [] });
  $effect(() => {
    if (part === "sound") services.systemSounds().then((v) => (soundList = v ?? soundList)).catch(() => {});
  });
  // Picking a sound plays it, as the Mac's picker does.
  function chooseSound(id: SoundName, choice: string) {
    const next = { ...(s.soundChoices ?? {}) };
    if (choice) next[id] = choice; else delete next[id];
    nook.saveSettings({ soundChoices: next });
    playChoice(id, choice);
  }

  async function openFolder() {
    try {
      folder = await services.openSoundsFolder();
      forgetCustomSounds();
      soundList = await services.systemSounds().catch(() => soundList);
    } catch (e) {
      message = String(e);
    }
  }
</script>



{#if part === "dictation" && flow && caps?.flow}
  <h3>{tr("Overal dicteren", "Dictate anywhere")}</h3>
  <div class="group">
    <label class="row">
      <span>{tr("Dicteren aanzetten", "Turn on dictation")}<br /><small class="faint">{tr("Houd {key} vast, praat en laat los: je woorden staan waar je typt, in elke app. Twee keer tikken is handsfree.", "Hold {key}, talk and let go: your words appear where you type, in any app. Tap twice for hands-free.", { key: flow.settings.key })}</small></span>
      <input type="checkbox" role="switch" checked={flow.settings.enabled} onchange={(e) => saveFlow({ enabled: e.currentTarget.checked })} />
    </label>
    {#if flow.settings.enabled}
      <label class="row"><span>{tr("Toets", "Key")}</span><input value={flow.settings.key} onchange={(e) => saveFlow({ key: e.currentTarget.value })} /></label>
      <label class="row">
        <span>{tr("Netjes maken door Nook", "Tidy up by Nook")}<br /><small class="faint">{tr("Haalt eh, herhalingen en verbeteringen weg (\"om 3 uur, nee 4 uur\" → \"om 4 uur\"). Met je eigen brein. In terminals en code-editors blijft het letterlijk.", "Removes ums, repetitions and corrections (\"at 3, no 4\" → \"at 4\"). With your own brain. In terminals and code editors it stays verbatim.")}</small></span>
        <input type="checkbox" role="switch" checked={flow.settings.cleanup} onchange={(e) => saveFlow({ cleanup: e.currentTarget.checked })} />
      </label>
      <label class="row">
        <span>{tr("Promptmodus", "Prompt mode")}<br /><small class="faint">{tr("Wat je zegt wordt een duidelijke opdracht voor een agent: doel, context, stappen, grenzen, klaar als.", "What you say becomes a clear task for an agent: goal, context, steps, limits, done when.")}</small></span>
        <input type="checkbox" role="switch" checked={flow.settings.promptMode} onchange={(e) => saveFlow({ promptMode: e.currentTarget.checked })} />
      </label>
      <label class="row">
        <span>{tr("Plakken in", "Paste in")}</span>
        <select value={flow.settings.translateTo} onchange={(e) => saveFlow({ translateTo: e.currentTarget.value })}>
          <option value="">{tr("De taal waarin je spreekt", "The language you speak")}</option>
          {#each ["Nederlands", "English", "Deutsch", "Français", "Español"] as l (l)}<option value={l}>{l}</option>{/each}
        </select>
      </label>
      <label class="row">
        <span>{tr("Geschiedenis bewaren", "Keep history")}<br /><small class="faint">{tr("De laatste 200 dicteringen, alleen op deze computer.", "The last 200 dictations, only on this computer.")}</small></span>
        <input type="checkbox" role="switch" checked={flow.settings.keepHistory} onchange={(e) => saveFlow({ keepHistory: e.currentTarget.checked })} />
      </label>
      <div class="col">
        <span>{tr("Woordenboek", "Dictionary")}</span>
        <textarea rows="4" bind:value={dictionary} onchange={() => services.saveFlowDictionary(dictionary)}></textarea>
        <small class="faint">{tr("Eén per regel. Een woord: altijd zo gespeld (Supabase). \"cloud code => Claude Code\": vervangen. \"mijn handtekening :: Groet,\\nMichan\": zeg de korte zin en krijg de hele tekst.", "One per line. A word: always spelled this way (Supabase). \"cloud code => Claude Code\": replace. \"my signature :: Regards,\\nMichan\": say the short phrase and get the whole text.")}</small>
      </div>
      {#if flow.words > 0}
        <div class="row"><span>{tr("Gedicteerd", "Dictated")}</span><span class="faint">{tr("{n} woorden", "{n} words", { n: flow.words })} · {tr("{n} woorden per minuut", "{n} words per minute", { n: flow.wordsPerMinute })} · {tr("{n} minuten bespaard", "{n} minutes saved", { n: Math.round(flow.minutesSaved) })} · {tr("{n} dagen op rij", "{n} days in a row", { n: flow.streak })}</span></div>
      {/if}
      {#if flow.history.length}
        <div class="col">
          <span>{tr("Recent", "Recent")}</span>
          {#each flow.history as entry (entry.id)}
            <div class="entry"><span>{entry.text}</span><button class="ghost" title={tr("Kopiëren", "Copy")} onclick={() => navigator.clipboard.writeText(entry.text)}>⧉</button></div>
          {/each}
          <button class="danger" onclick={async () => { await services.clearFlowHistory(); flow = await services.flowView(); }}>{tr("Geschiedenis wissen", "Clear history")}</button>
        </div>
      {/if}
    {/if}
  </div>
{/if}

{#if part === "dictation" && prefs && caps?.microphone}
  <h3>{tr("Spraakherkenning", "Speech recognition")}</h3>
  <div class="group">
    {#each engines.filter((e) => !e.when || e.when()) as engine (engine.id)}
      <label class="row">
        <span>{engine.title}<br /><small class="faint">{engine.detail}</small></span>
        <input type="radio" name="engine" checked={prefs.speechEngine === engine.id} onchange={() => choose(engine.id)} />
      </label>
      {#if pending === engine.id}
        <div class="row confirm">
          <span>{tr("Je opnames gaan dan naar {service}.", "Your recordings then go to {service}.", { service: engine.title })}</span>
          <span class="inline"><button class="primary" onclick={() => choose(engine.id)}>{tr("Ja, gebruik {service}", "Yes, use {service}", { service: engine.title })}</button><button onclick={() => (pending = null)}>{tr("Nee", "No")}</button></span>
        </div>
      {/if}
    {/each}
    {#if prefs.speechEngine === "local"}
      <label class="row">
        <span>{tr("Model van whisper.cpp", "whisper.cpp model")}<br /><small class="faint">{info?.whisper ? tr("Gevonden: {path}.", "Found: {path}.", { path: info.whisper }) : tr("whisper-cli staat niet op deze computer.", "whisper-cli isn't on this computer.")} {tr("Het pad naar een ggml-….bin-bestand.", "The path to a ggml-….bin file.")}</small></span>
        <input placeholder={tr("/pad/naar/ggml-base.bin", "/path/to/ggml-base.bin")} value={prefs.whisperModel} onchange={(e) => save({ whisperModel: e.currentTarget.value.trim() })} />
      </label>
    {/if}
    {#if info?.speechEngineReady}<p class="err note">{info.speechEngineReady}</p>{:else}<p class="faint note">{tr("Klaar om te luisteren.", "Ready to listen.")}</p>{/if}
  </div>
{/if}


{#if part === "notices" && caps?.desktop}
  <!-- The Mac's "How notifications show" (`NoticeRulesSettings`, part how): one way of showing per source, then quiet
       hours for all of them. Every notice asks `notice_decide` in Rust, so these rules are the only ones. -->
  <h3>{tr("Hoe meldingen verschijnen", "How notifications show")}</h3>
  <p class="section-info">{tr("Bij “Niet tonen” springt er niets op en klinkt er niets. Een vraag of toestemmingsverzoek van een agent bereikt je altijd.", "With “Don't show” nothing pops up or sounds. An agent's question or permission request always reaches you.")}</p>
  <div class="group">
    {#each sources as source (source.id)}
      <label class="row">
        <span>{source.title}<br /><small class="faint">{source.detail}</small></span>
        <select value={styleOf(source.id)} onchange={(e) => setStyle(source.id, e.currentTarget.value as NoticeStyle)}>
          {#each styleChoices as c (c.id)}<option value={c.id}>{c.title}</option>{/each}
        </select>
      </label>
    {/each}
    <label class="row">
      <span>{tr("Stille uren", "Quiet hours")}<br /><small class="faint">{tr("Tussen deze uren geen pop-ups, geluiden of meldingen op je telefoon. Alles komt wel in de lijst.", "No pop-ups, sounds or phone notifications between these hours. Everything still goes into the list.")}</small></span>
      <input type="checkbox" role="switch" checked={!!rules.quietHours} onchange={(e) => setRules({ quietHours: e.currentTarget.checked ? (rules.quietHours ?? { from: 22, to: 7, allowsUrgent: true }) : null })} />
    </label>
    {#if rules.quietHours}
      {@const hours = rules.quietHours}
      <div class="row">
        <span class="inline">
          <label class="hour">{tr("Van", "From")} <select value={hours.from} onchange={(e) => setRules({ quietHours: { ...hours, from: Number(e.currentTarget.value) } })}>{#each HOURS as h (h)}<option value={h}>{h}:00</option>{/each}</select></label>
          <label class="hour">{tr("Tot", "Until")} <select value={hours.to} onchange={(e) => setRules({ quietHours: { ...hours, to: Number(e.currentTarget.value) } })}>{#each HOURS as h (h)}<option value={h}>{h}:00</option>{/each}</select></label>
        </span>
      </div>
      <label class="row"><span>{tr("Toestemming en vragen komen toch door", "Approvals and questions still come through")}</span><input type="checkbox" role="switch" checked={hours.allowsUrgent} onchange={(e) => setRules({ quietHours: { ...hours, allowsUrgent: e.currentTarget.checked } })} /></label>
    {/if}
    <p class="faint note">{tr("Met Oké verdwijnt een melding meteen. Anders gaat hij na een paar seconden vanzelf weg, behalve zolang je pointer op de balk staat.", "With OK a notice disappears right away. Otherwise it goes away by itself after a few seconds, except while your pointer is on the bar.")}</p>
  </div>
{/if}

{#if part === "sound"}
  <!-- The Mac's `soundSection`: the sounds first, one picker per moment with a button to hear it, then speaking. -->
  <h3>{tr("Geluiden", "Sounds")}</h3>
  {#if caps?.desktop}<p class="section-info">{tr("Zet attention, done of error (.wav, .mp3, .ogg, .m4a) in de map om een eigen geluid te gebruiken.", "Place attention, done or error (.wav, .mp3, .ogg, .m4a) files in the folder to use custom sounds.")}{folder ? ` ${folder}` : ""}</p>{/if}
  <div class="group">
    <label class="row"><span>{tr("Geluid als een agent op je wacht of klaar is", "Sound when an agent is waiting or finished")}</span><input type="checkbox" role="switch" checked={s.sounds} onchange={(e) => nook.saveSettings({ sounds: e.currentTarget.checked })} /></label>
    {#each moments as moment (moment.id)}
      {@const choice = s.soundChoices?.[moment.id] ?? ""}
      {@const hasFile = soundList.custom.includes(moment.id)}
      <div class="row">
        <span>{moment.title}</span>
        <span class="sound-choice">
          <select value={choice} disabled={!s.sounds} onchange={(e) => chooseSound(moment.id, e.currentTarget.value)}>
            <option value="">{hasFile ? tr("Standaard (eigen bestand)", "Default (own file)") : tr("Standaard ({name})", "Default ({name})", { name: "Nook" })}</option>
            {#if soundList.system.length}<hr />{#each soundList.system as name (name)}<option value={name}>{name}</option>{/each}<hr />{/if}
            {#if hasFile || choice === "file"}<option value="file">{tr("Eigen bestand", "Own file")}</option>{/if}
            <option value="none">{tr("Geen geluid", "No sound")}</option>
          </select>
          <IconButton class="ghost" title={tr("Laat horen", "Play")} size={22} disabled={!s.sounds || choice === "none"} onclick={() => playChoice(moment.id, choice)}><Ico name="volume-2" size={13} /></IconButton>
        </span>
      </div>
    {/each}
    {#if caps?.desktop}
      <div class="row">
        <span>{tr("Eigen geluiden", "Custom sounds")}</span>
        <button class="capsule" disabled={!s.sounds} onclick={openFolder}>{tr("Open map", "Open folder")}</button>
      </div>
    {/if}
  </div>
  {#if caps?.microphone || caps?.speechOutput}
    <h3>{tr("Praten", "Speaking")}</h3>
    <p class="section-info">{tr("Met het wekwoord aan luistert Nook op deze computer. Geluid wordt nooit bewaard of verstuurd, en het microfoonpictogram in de taakbalk blijft zichtbaar.", "With the wake word on, Nook listens on this computer. Audio is never stored or sent, and the microphone icon in the taskbar stays visible.")}</p>
    <div class="group">
      <label class="row">
        <span>{tr("Lees antwoorden voor als ik iets zeg", "Read answers aloud when I speak")}</span>
        <input type="checkbox" role="switch" checked={s.speakAnswers} disabled={!caps?.speechOutput} onchange={(e) => nook.saveSettings({ speakAnswers: e.currentTarget.checked })} />
      </label>
      <label class="row">
        <span>{tr("Luister naar “Hé Nook”", "Listen for “Hey Nook”")}</span>
        <input type="checkbox" role="switch" checked={s.wakeWord} disabled={!caps?.wakeWord} onchange={(e) => nook.saveSettings({ wakeWord: e.currentTarget.checked })} />
      </label>
    </div>
    {#if !caps?.speechOutput && caps?.notes?.speechOutput}<p class="faint note">{caps.notes.speechOutput}</p>{/if}
    {#if !caps?.wakeWord && caps?.notes?.wakeWord}<p class="faint note">{caps.notes.wakeWord}</p>{/if}
  {/if}
{/if}
{#if part === "quiet" && caps?.desktop}
  <h3>{tr("Meetings en scherm delen", "Meetings and screen sharing")}</h3>
  <div class="group">
    <label class="row">
      <span>{tr("Als je je scherm deelt", "When you share your screen")}<br /><small class="faint">{tr("Bijvoorbeeld een presentatie in Zoom, Teams of Google Meet, of een schermopname.", "For example a presentation in Zoom, Teams or Google Meet, or a screen recording.")}</small></span>
      <select value={s.quietWhileSharing} onchange={(e) => nook.saveSettings({ quietWhileSharing: e.currentTarget.value as QuietBehavior })}>
        {#each behaviors as b (b.id)}<option value={b.id}>{b.title}</option>{/each}
      </select>
    </label>
    {#if s.quietWhileSharing === "hideFromShare" && !caps.captureExclusion}<p class="faint note">{caps.notes?.captureExclusion}</p>{/if}
    <label class="row">
      <span>{tr("Tijdens een meeting", "During a meeting")}<br /><small class="faint">{tr("Een gesprek in Zoom, Teams of in je browser, of een afspraak die nu bezig is.", "A call in Zoom, Teams or your browser, or an event that is going on now.")}</small></span>
      <select value={s.quietInMeetings === "hideFromShare" ? "quiet" : s.quietInMeetings} onchange={(e) => nook.saveSettings({ quietInMeetings: e.currentTarget.value as QuietBehavior })}>
        {#each meetingBehaviors as b (b.id)}<option value={b.id}>{b.title}</option>{/each}
      </select>
    </label>
    <label class="row">
      <span>{tr("Afspraken in je agenda tellen mee", "Count events in your calendar")}<br /><small class="faint">{tr("Een afspraak die nu bezig is geldt ook als meeting, niet alleen een gesprek. Afspraken van een hele dag tellen niet.", "An event going on now also counts as a meeting, not only a call. All-day events do not count.")}</small></span>
      <input type="checkbox" role="switch" checked={s.quietUseCalendar} onchange={(e) => nook.saveSettings({ quietUseCalendar: e.currentTarget.checked })} />
    </label>
    {#if caps.captureExclusion}
      <label class="row">
        <span>{tr("Nook altijd buiten schermdelen houden", "Always keep Nook out of screen sharing")}<br /><small class="faint">{tr("Nook komt nooit in een gedeeld scherm, schermafbeelding of opname, ook niet in de eerste seconden voordat Nook het delen ziet. Jij ziet hem gewoon.", "Nook never appears in a shared screen, screenshot or recording, not even in the first seconds before Nook notices the sharing. You still see it.")}</small></span>
        <input type="checkbox" role="switch" checked={s.hideFromCaptures} onchange={(e) => nook.saveSettings({ hideFromCaptures: e.currentTarget.checked })} />
      </label>
      <label class="row">
        <span>{tr("Nook tonen in je schermafbeeldingen", "Show Nook in your screenshots")}<br /><small class="faint">{tr("Het Knipprogramma van Windows telt niet als scherm delen, dus Nook staat op je schermafbeeldingen en op opnames die je daarmee maakt. Werkt niet als Nook altijd buiten schermdelen blijft.", "Windows' Snipping Tool doesn't count as screen sharing, so Nook shows up in your screenshots and recordings made with it. Doesn't work if Nook always stays out of screen sharing.")}</small></span>
        <input type="checkbox" role="switch" disabled={s.hideFromCaptures} checked={s.showInScreenshots} onchange={(e) => nook.saveSettings({ showInScreenshots: e.currentTarget.checked })} />
      </label>
    {/if}
    <div class="row">
      <span>{tr("Nu", "Right now")}</span>
      <span class="faint">{quietNow?.status ?? "…"}</span>
    </div>
    {#if !caps.shareDetection}<p class="faint note">{caps.notes?.shareDetection}</p>{/if}
  </div>
{/if}
{#if message}<p class="err">{message}</p>{/if}

<style>
  small { font: var(--text-detail); line-height: 1.3; display: inline-block; }
  .col { display: flex; flex-direction: column; gap: 6px; padding: 10px 0; border-bottom: 1px solid var(--line); }
  .col textarea { font: var(--text-code); }
  .entry { display: flex; gap: 8px; align-items: center; font: var(--text-detail); }
  .entry span { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .inline { display: flex; gap: 6px; }
  .confirm span:first-child { color: var(--amber); }
  .sound-choice { display: inline-flex; align-items: center; gap: var(--space-4); }
  .hour { display: inline-flex; align-items: center; gap: var(--space-6); color: var(--text2); }
</style>
