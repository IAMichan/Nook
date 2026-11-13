<script lang="ts">
  // Stem en geluid: praten en voorlezen, de spraakherkenning, "Hé Nook", overal dicteren (Flow), de Notetaker,
  // geluiden (ook je eigen) en hoe Nook zich gedraagt in meetings en als je je scherm deelt.
  import { nook } from "../../lib/state.svelte";
  import { services, type FlowView, type ServicePrefs, type VoiceInfo, type SpeechEngine, type FlowSettings, type QuietView } from "../../lib/services";
  import type { QuietBehavior } from "../../lib/types";
  import { play, forgetCustomSounds } from "../../lib/sounds";
  import { tr } from "../../lib/i18n.svelte";

  const s = $derived(nook.settings!);
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
    { id: "quiet", title: tr("Stil: geen meldingen of geluiden", "Quiet: no notices or sounds") },
    { id: "hideFromShare", title: tr("Verbergen voor kijkers (jij ziet Nook nog)", "Hide from viewers (you still see Nook)") },
    { id: "hide", title: tr("Helemaal verbergen, ook voor jou", "Hide completely, from you too") },
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

  async function test() {
    message = null;
    try {
      await services.speak(tr("Hallo, ik ben Nook. Zo klink ik als ik een antwoord voorlees.", "Hi, I'm Nook. This is how I sound when I read an answer aloud."));
    } catch (e) {
      message = String(e);
    }
  }

  async function openFolder() {
    try {
      folder = await services.openSoundsFolder();
      forgetCustomSounds();
    } catch (e) {
      message = String(e);
    }
  }
</script>

<h2>{tr("Stem en geluid", "Voice and sound")}</h2>

{#if caps?.microphone || caps?.speechOutput}
  <h3>{tr("Praten", "Talk")}</h3>
  <div class="group">
    <label class="row">
      <span>{tr("Lees antwoorden voor als ik iets zeg", "Read answers aloud when I say something")}</span>
      <input type="checkbox" checked={s.speakAnswers} disabled={!caps?.speechOutput} onchange={(e) => nook.saveSettings({ speakAnswers: e.currentTarget.checked })} />
    </label>
    {#if caps?.speechOutput}
      <div class="row"><span>{tr("Hoe Nook klinkt", "How Nook sounds")}</span><button onclick={test}>{tr("Laat horen", "Play")}</button></div>
    {:else}
      <p class="faint note">{caps?.notes?.speechOutput}</p>
    {/if}
    <label class="row">
      <span>{tr("Luister naar “Hé Nook”", "Listen for “Hey Nook”")}</span>
      <input type="checkbox" checked={s.wakeWord} disabled={!caps?.wakeWord} onchange={(e) => nook.saveSettings({ wakeWord: e.currentTarget.checked })} />
    </label>
    {#if !caps?.wakeWord}<p class="faint note">{caps?.notes?.wakeWord}</p>{/if}
    {#if s.shortcuts.talk}<p class="faint note">{tr("Praten: druk {keys} of de microfoon naast het invoerveld. Na een stilte stopt Nook vanzelf.", "Talk: press {keys} or the microphone next to the input field. After a silence Nook stops by itself.", { keys: s.shortcuts.talk })}</p>{/if}
  </div>
{/if}

{#if prefs && caps?.microphone}
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

{#if flow && caps?.flow}
  <h3>{tr("Overal dicteren", "Dictate anywhere")}</h3>
  <div class="group">
    <label class="row">
      <span>{tr("Overal dicteren", "Dictate anywhere")}<br /><small class="faint">{tr("Houd {key} vast, praat en laat los: je woorden staan waar je typt, in elke app. Twee keer tikken is handsfree.", "Hold {key}, talk and let go: your words appear where you type, in any app. Tap twice for hands-free.", { key: flow.settings.key })}</small></span>
      <input type="checkbox" checked={flow.settings.enabled} onchange={(e) => saveFlow({ enabled: e.currentTarget.checked })} />
    </label>
    {#if flow.settings.enabled}
      <label class="row"><span>{tr("Toets", "Key")}</span><input value={flow.settings.key} onchange={(e) => saveFlow({ key: e.currentTarget.value })} /></label>
      <label class="row">
        <span>{tr("Netjes maken door Nook", "Tidy up by Nook")}<br /><small class="faint">{tr("Haalt eh, herhalingen en verbeteringen weg (\"om 3 uur, nee 4 uur\" → \"om 4 uur\"). Met je eigen brein. In terminals en code-editors blijft het letterlijk.", "Removes ums, repetitions and corrections (\"at 3, no 4\" → \"at 4\"). With your own brain. In terminals and code editors it stays verbatim.")}</small></span>
        <input type="checkbox" checked={flow.settings.cleanup} onchange={(e) => saveFlow({ cleanup: e.currentTarget.checked })} />
      </label>
      <label class="row">
        <span>{tr("Promptmodus", "Prompt mode")}<br /><small class="faint">{tr("Wat je zegt wordt een duidelijke opdracht voor een agent: doel, context, stappen, grenzen, klaar als.", "What you say becomes a clear task for an agent: goal, context, steps, limits, done when.")}</small></span>
        <input type="checkbox" checked={flow.settings.promptMode} onchange={(e) => saveFlow({ promptMode: e.currentTarget.checked })} />
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
        <input type="checkbox" checked={flow.settings.keepHistory} onchange={(e) => saveFlow({ keepHistory: e.currentTarget.checked })} />
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

{#if prefs && caps?.microphone}
  <h3>{tr("Notetaker", "Notetaker")}</h3>
  <div class="group">
    <label class="row">
      <span>{tr("Sneltoets", "Shortcut")}<br /><small class="faint">{caps.systemAudio ? tr("Een gesprek opnemen: je microfoon en wat de computer afspeelt. Er komt geen bot in het gesprek: vertel de anderen dat je notities maakt.", "Record a call: your microphone and what the computer plays. No bot joins the call: tell the others you're taking notes.") : tr("Een gesprek opnemen: je microfoon. Er komt geen bot in het gesprek: vertel de anderen dat je notities maakt.", "Record a call: your microphone. No bot joins the call: tell the others you're taking notes.")}</small></span>
      <input value={prefs.notesShortcut} onchange={(e) => save({ notesShortcut: e.currentTarget.value })} />
    </label>
    {#if !caps.systemAudio}<p class="faint note">{caps.notes?.systemAudio}</p>{/if}
  </div>
{/if}

{#if caps?.desktop}
  <h3>{tr("Meldingen", "Notices")}</h3>
  <div class="group">
    <label class="row">
      <span>{tr("Grootte van meldingen", "Notice size")}<br /><small class="faint">{tr("Voor elke agent die klaar is, vastloopt of op je wacht, in de terminal of in de werkruimte. Uitgebreid toont een kaart met de samenvatting en wat er veranderd is; compact één smalle regel in de balk.", "For every agent that is done, gets stuck or waits for you, in the terminal or in the workspace. Detailed shows a card with the summary and what changed; compact one narrow line in the bar.")}</small></span>
      <select value={s.agentNotice ?? "detailed"} onchange={(e) => nook.saveSettings({ agentNotice: e.currentTarget.value as "detailed" | "compact" })}>
        <option value="detailed">{tr("Uitgebreid", "Detailed")}</option>
        <option value="compact">{tr("Compact", "Compact")}</option>
      </select>
    </label>
    <p class="faint note">{tr("Met Oké verdwijnt een melding meteen. Anders gaat hij na een paar seconden vanzelf weg, behalve zolang je pointer op de balk staat.", "With OK a notice disappears right away. Otherwise it goes away by itself after a few seconds, except while your pointer is on the bar.")}</p>
  </div>
{/if}

<h3>{tr("Geluiden", "Sounds")}</h3>
<div class="group">
  <label class="row"><span>{tr("Geluid als Nook of een agent op je wacht of klaar is", "Sound when Nook or an agent waits for you or is done")}</span><input type="checkbox" checked={s.sounds} onchange={(e) => nook.saveSettings({ sounds: e.currentTarget.checked })} /></label>
  <div class="row">
    <span>{tr("Laat horen", "Play")}</span>
    <span class="inline">
      <button onclick={() => play("attention")}>{tr("Aandacht", "Attention")}</button>
      <button onclick={() => play("done")}>{tr("Klaar", "Done")}</button>
      <button onclick={() => play("error")}>{tr("Fout", "Error")}</button>
    </span>
  </div>
  {#if caps?.desktop}
    <div class="row">
      <span>{tr("Eigen geluiden", "Your own sounds")}<br /><small class="faint">{tr("Zet attention, done of error (.wav, .mp3, .ogg, .m4a) in de map om een eigen geluid te gebruiken.", "Put attention, done or error (.wav, .mp3, .ogg, .m4a) in the folder to use your own sound.")}{folder ? ` ${folder}` : ""}</small></span>
      <button onclick={openFolder}>{tr("Open map", "Open folder")}</button>
    </div>
  {/if}
</div>
{#if caps?.desktop}
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
      <span>{tr("Tijdens een meeting", "During a meeting")}<br /><small class="faint">{tr("Een gesprek in Zoom, Teams of in je browser, of een afspraak die nu bezig is.", "A call in Zoom, Teams or your browser, or an appointment happening now.")}</small></span>
      <select value={s.quietInMeetings === "hideFromShare" ? "quiet" : s.quietInMeetings} onchange={(e) => nook.saveSettings({ quietInMeetings: e.currentTarget.value as QuietBehavior })}>
        {#each meetingBehaviors as b (b.id)}<option value={b.id}>{b.title}</option>{/each}
      </select>
    </label>
    <label class="row">
      <span>{tr("Afspraken in je agenda tellen mee", "Calendar events count too")}<br /><small class="faint">{tr("Een afspraak die nu bezig is geldt ook als meeting, niet alleen een gesprek. Afspraken van een hele dag tellen niet.", "An event happening now also counts as a meeting, not just a call. All-day events don't count.")}</small></span>
      <input type="checkbox" checked={s.quietUseCalendar} onchange={(e) => nook.saveSettings({ quietUseCalendar: e.currentTarget.checked })} />
    </label>
    {#if caps.captureExclusion}
      <label class="row">
        <span>{tr("Nook altijd buiten schermdelen houden", "Always keep Nook out of screen sharing")}<br /><small class="faint">{tr("Nook komt nooit in een gedeeld scherm, schermafbeelding of opname, ook niet in de eerste seconden voordat Nook het delen ziet. Jij ziet hem gewoon.", "Nook never appears in a shared screen, screenshot or recording, not even in the first seconds before Nook notices the sharing. You still see it.")}</small></span>
        <input type="checkbox" checked={s.hideFromCaptures} onchange={(e) => nook.saveSettings({ hideFromCaptures: e.currentTarget.checked })} />
      </label>
      <label class="row">
        <span>{tr("Nook tonen in je schermafbeeldingen", "Show Nook in your screenshots")}<br /><small class="faint">{tr("Het Knipprogramma van Windows telt niet als scherm delen, dus Nook staat op je schermafbeeldingen en op opnames die je daarmee maakt. Werkt niet als Nook altijd buiten schermdelen blijft.", "Windows' Snipping Tool doesn't count as screen sharing, so Nook shows up in your screenshots and recordings made with it. Doesn't work if Nook always stays out of screen sharing.")}</small></span>
        <input type="checkbox" checked={s.showInScreenshots} onchange={(e) => nook.saveSettings({ showInScreenshots: e.currentTarget.checked })} />
      </label>
    {/if}
    <div class="row">
      <span>{tr("Nu", "Right now")}</span>
      <span class="faint">{quietNow?.status ?? "…"}</span>
    </div>
    {#if !caps.shareDetection}<p class="faint note">{caps.notes?.shareDetection}</p>{/if}
    <p class="faint note">{caps.os === "windows" ? tr("Nook ziet dat je je scherm deelt aan de deelbalk van Zoom, Teams, Webex, Slack of je browser, en aan het Knipprogramma van Windows. Een meeting herkent hij aan een gespreks-app of meetingsite die je microfoon gebruikt, aan een gesprek dat de Notetaker opneemt en, als je dat wilt, aan je agenda. Helemaal verbergen haalt ook het hoofdvenster en de balk weg tot het voorbij is; toestemmingsvragen van agents wachten dan ook.", "Nook sees that you share your screen by the sharing bar of Zoom, Teams, Webex, Slack or your browser, and by Windows' Snipping Tool. It recognizes a meeting by a call app or meeting site that uses your microphone, by a call the Notetaker is recording and, if you want, by your calendar. Hiding completely also removes the main window and the bar until it's over; permission requests from agents wait too.") : tr("Nook ziet dat je je scherm deelt aan de deelbalk van Zoom, Teams, Webex, Slack of je browser. Een meeting herkent hij aan een gespreks-app of meetingsite die je microfoon gebruikt, aan een gesprek dat de Notetaker opneemt en, als je dat wilt, aan je agenda. Helemaal verbergen haalt ook het hoofdvenster en de balk weg tot het voorbij is; toestemmingsvragen van agents wachten dan ook.", "Nook sees that you share your screen by the sharing bar of Zoom, Teams, Webex, Slack or your browser. It recognizes a meeting by a call app or meeting site that uses your microphone, by a call the Notetaker is recording and, if you want, by your calendar. Hiding completely also removes the main window and the bar until it's over; permission requests from agents wait too.")}</p>
  </div>
{/if}
{#if message}<p class="err">{message}</p>{/if}

<style>
  small { font-size: 11px; line-height: 1.35; display: inline-block; max-width: 460px; }
  .col { display: flex; flex-direction: column; gap: 6px; padding: 10px 0; border-bottom: 1px solid var(--line); }
  .col textarea { font-family: var(--mono); font-size: 12px; }
  .entry { display: flex; gap: 8px; align-items: center; font-size: 12px; }
  .entry span { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .inline { display: flex; gap: 6px; }
  .confirm span:first-child { color: var(--amber); }
</style>
