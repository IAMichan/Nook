<script lang="ts">
  // Stem en geluid: praten en voorlezen, de spraakherkenning, "Hé Nook", overal dicteren (Flow), de Notetaker en
  // geluiden (ook je eigen).
  import { nook } from "../../lib/state.svelte";
  import { services, type FlowView, type ServicePrefs, type VoiceInfo, type SpeechEngine, type FlowSettings } from "../../lib/services";
  import { play, forgetCustomSounds } from "../../lib/sounds";

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

  async function saveFlow(patch: Partial<FlowSettings>) {
    if (!flow) return;
    await services.saveFlowSettings({ ...flow.settings, ...patch });
    flow = await services.flowView();
  }

  const engines: { id: SpeechEngine; title: string; detail: string; when?: () => boolean }[] = [
    { id: "local", title: "Op deze computer (whisper.cpp)", detail: "Niets gaat naar buiten. Vraagt het programma whisper-cli en een model." },
    { id: "windows", title: "Spraakherkenning van Windows", detail: "Vrije tekst gaat via de online spraakherkenning van Microsoft. Alleen praten en Flow.", when: () => caps?.os === "windows" },
    { id: "openai", title: "OpenAI", detail: "Je opname gaat naar OpenAI, met je eigen sleutel (Instellingen › Brein)." },
    { id: "groq", title: "Groq", detail: "Je opname gaat naar Groq, met je eigen sleutel (Instellingen › Brein)." },
  ];

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
      await services.speak("Hallo, ik ben Nook. Zo klink ik als ik een antwoord voorlees.");
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

<h2>Stem en geluid</h2>

{#if caps?.microphone || caps?.speechOutput}
  <h3>Praten</h3>
  <div class="group">
    <label class="row">
      <span>Lees antwoorden voor als ik iets zeg</span>
      <input type="checkbox" checked={s.speakAnswers} disabled={!caps?.speechOutput} onchange={(e) => nook.saveSettings({ speakAnswers: e.currentTarget.checked })} />
    </label>
    {#if caps?.speechOutput}
      <div class="row"><span>Hoe Nook klinkt</span><button onclick={test}>Laat horen</button></div>
    {:else}
      <p class="faint note">{caps?.notes?.speechOutput}</p>
    {/if}
    <label class="row">
      <span>Luister naar “Hé Nook”</span>
      <input type="checkbox" checked={s.wakeWord} disabled={!caps?.wakeWord} onchange={(e) => nook.saveSettings({ wakeWord: e.currentTarget.checked })} />
    </label>
    {#if !caps?.wakeWord}<p class="faint note">{caps?.notes?.wakeWord}</p>{/if}
    {#if s.shortcuts.talk}<p class="faint note">Praten: druk {s.shortcuts.talk} of de microfoon naast het invoerveld. Na een stilte stopt Nook vanzelf.</p>{/if}
  </div>
{/if}

{#if prefs && caps?.microphone}
  <h3>Spraakherkenning</h3>
  <div class="group">
    {#each engines.filter((e) => !e.when || e.when()) as engine (engine.id)}
      <label class="row">
        <span>{engine.title}<br /><small class="faint">{engine.detail}</small></span>
        <input type="radio" name="engine" checked={prefs.speechEngine === engine.id} onchange={() => choose(engine.id)} />
      </label>
      {#if pending === engine.id}
        <div class="row confirm">
          <span>Je opnames gaan dan naar {engine.title}.</span>
          <span class="inline"><button class="primary" onclick={() => choose(engine.id)}>Ja, gebruik {engine.title}</button><button onclick={() => (pending = null)}>Nee</button></span>
        </div>
      {/if}
    {/each}
    {#if prefs.speechEngine === "local"}
      <label class="row">
        <span>Model van whisper.cpp<br /><small class="faint">{info?.whisper ? `Gevonden: ${info.whisper}.` : "whisper-cli staat niet op deze computer."} Het pad naar een ggml-….bin-bestand.</small></span>
        <input placeholder="/pad/naar/ggml-base.bin" value={prefs.whisperModel} onchange={(e) => save({ whisperModel: e.currentTarget.value.trim() })} />
      </label>
    {/if}
    {#if info?.speechEngineReady}<p class="err note">{info.speechEngineReady}</p>{:else}<p class="faint note">Klaar om te luisteren.</p>{/if}
  </div>
{/if}

{#if flow && caps?.flow}
  <h3>Overal dicteren</h3>
  <div class="group">
    <label class="row">
      <span>Overal dicteren<br /><small class="faint">Houd {flow.settings.key} vast, praat en laat los: je woorden staan waar je typt, in elke app. Twee keer tikken is handsfree.</small></span>
      <input type="checkbox" checked={flow.settings.enabled} onchange={(e) => saveFlow({ enabled: e.currentTarget.checked })} />
    </label>
    {#if flow.settings.enabled}
      <label class="row"><span>Toets</span><input value={flow.settings.key} onchange={(e) => saveFlow({ key: e.currentTarget.value })} /></label>
      <label class="row">
        <span>Netjes maken door Nook<br /><small class="faint">Haalt eh, herhalingen en verbeteringen weg ("om 3 uur, nee 4 uur" → "om 4 uur"). Met je eigen brein. In terminals en code-editors blijft het letterlijk.</small></span>
        <input type="checkbox" checked={flow.settings.cleanup} onchange={(e) => saveFlow({ cleanup: e.currentTarget.checked })} />
      </label>
      <label class="row">
        <span>Promptmodus<br /><small class="faint">Wat je zegt wordt een duidelijke opdracht voor een agent: doel, context, stappen, grenzen, klaar als.</small></span>
        <input type="checkbox" checked={flow.settings.promptMode} onchange={(e) => saveFlow({ promptMode: e.currentTarget.checked })} />
      </label>
      <label class="row">
        <span>Plakken in</span>
        <select value={flow.settings.translateTo} onchange={(e) => saveFlow({ translateTo: e.currentTarget.value })}>
          <option value="">De taal waarin je spreekt</option>
          {#each ["Nederlands", "English", "Deutsch", "Français", "Español"] as l (l)}<option value={l}>{l}</option>{/each}
        </select>
      </label>
      <label class="row">
        <span>Geschiedenis bewaren<br /><small class="faint">De laatste 200 dicteringen, alleen op deze computer.</small></span>
        <input type="checkbox" checked={flow.settings.keepHistory} onchange={(e) => saveFlow({ keepHistory: e.currentTarget.checked })} />
      </label>
      <div class="col">
        <span>Woordenboek</span>
        <textarea rows="4" bind:value={dictionary} onchange={() => services.saveFlowDictionary(dictionary)}></textarea>
        <small class="faint">Eén per regel. Een woord: altijd zo gespeld (Supabase). "cloud code => Claude Code": vervangen. "mijn handtekening :: Groet,\nMichan": zeg de korte zin en krijg de hele tekst.</small>
      </div>
      {#if flow.words > 0}
        <div class="row"><span>Gedicteerd</span><span class="faint">{flow.words} woorden · {flow.wordsPerMinute} woorden per minuut · {Math.round(flow.minutesSaved)} minuten bespaard · {flow.streak} dagen op rij</span></div>
      {/if}
      {#if flow.history.length}
        <div class="col">
          <span>Recent</span>
          {#each flow.history as entry (entry.id)}
            <div class="entry"><span>{entry.text}</span><button class="ghost" title="Kopiëren" onclick={() => navigator.clipboard.writeText(entry.text)}>⧉</button></div>
          {/each}
          <button class="danger" onclick={async () => { await services.clearFlowHistory(); flow = await services.flowView(); }}>Geschiedenis wissen</button>
        </div>
      {/if}
    {/if}
  </div>
{/if}

{#if prefs && caps?.microphone}
  <h3>Notetaker</h3>
  <div class="group">
    <label class="row">
      <span>Sneltoets<br /><small class="faint">Een gesprek opnemen: je microfoon{caps.systemAudio ? " en wat de computer afspeelt" : ""}. Er komt geen bot in het gesprek: vertel de anderen dat je notities maakt.</small></span>
      <input value={prefs.notesShortcut} onchange={(e) => save({ notesShortcut: e.currentTarget.value })} />
    </label>
    {#if !caps.systemAudio}<p class="faint note">{caps.notes?.systemAudio}</p>{/if}
  </div>
{/if}

<h3>Geluiden</h3>
<div class="group">
  <label class="row"><span>Geluid als Nook of een agent op je wacht of klaar is</span><input type="checkbox" checked={s.sounds} onchange={(e) => nook.saveSettings({ sounds: e.currentTarget.checked })} /></label>
  <div class="row">
    <span>Laat horen</span>
    <span class="inline">
      <button onclick={() => play("attention")}>Aandacht</button>
      <button onclick={() => play("done")}>Klaar</button>
      <button onclick={() => play("error")}>Fout</button>
    </span>
  </div>
  {#if caps?.desktop}
    <div class="row">
      <span>Eigen geluiden<br /><small class="faint">Zet attention, done of error (.wav, .mp3, .ogg, .m4a) in de map om een eigen geluid te gebruiken.{folder ? ` ${folder}` : ""}</small></span>
      <button onclick={openFolder}>Open map</button>
    </div>
  {/if}
</div>
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
