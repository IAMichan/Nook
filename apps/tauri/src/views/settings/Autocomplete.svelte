<script lang="ts">
  // Instellingen › Aanvullen: zinnen aanvullen terwijl je typt, in elke app (Autocomplete Anywhere op de Mac). Tabs:
  // Algemeen, Apps, Stijl en context, Testen en Statistiek. Standaard uit, en standaard alleen met een model op deze
  // computer.
  import { nook } from "../../lib/state.svelte";
  import {
    autocomplete, autocompleteEvents, appRule, offByDefault, withAppRule,
    type AutocompleteSettings, type AutocompleteStatus, type AutocompleteView, type AppRule, type TriState,
  } from "../../lib/autocomplete";
  import Playground from "./AutocompletePlayground.svelte";
  import { tr } from "../../lib/i18n.svelte";

  type Tab = "general" | "apps" | "style" | "playground" | "stats";
  const tabs: { id: Tab; title: string }[] = $derived([
    { id: "general", title: tr("Algemeen", "General") },
    { id: "apps", title: tr("Apps", "Apps") },
    { id: "style", title: tr("Stijl en context", "Style and context") },
    { id: "playground", title: tr("Testen", "Try it") },
    { id: "stats", title: tr("Statistiek", "Statistics") },
  ]);
  let tab = $state<Tab>((localStorage.getItem("autocomplete.tab") as Tab) ?? "general");
  $effect(() => {
    localStorage.setItem("autocomplete.tab", tab);
  });

  const s = $derived(nook.settings!);
  const ac = $derived(s.autocomplete);
  const caps = $derived(nook.info?.capabilities);
  let view = $state<AutocompleteView | null>(null);
  let status = $state<AutocompleteStatus | null>(null);
  let models = $state<string[]>([]);
  let modelError = $state<string | null>(null);
  let confirmBrain = $state(false);
  let openApp = $state<string | null>(null);
  let newApp = $state("");
  let confirmReset = $state(false);

  async function load() {
    view = await autocomplete.view();
    status = view.status;
  }
  $effect(() => {
    load();
    const un = autocompleteEvents.onStatus((st) => (status = st));
    return () => {
      un.then((f) => f());
    };
  });

  async function loadModels() {
    modelError = null;
    try {
      models = await autocomplete.models();
    } catch (e) {
      models = [];
      modelError = String(e);
    }
  }
  $effect(() => {
    if (tab === "general" && ac.engine === "local") loadModels();
  });

  async function save(patch: Partial<AutocompleteSettings>) {
    await nook.saveSettings({ autocomplete: { ...ac, ...patch } });
    view = await autocomplete.view();
  }

  async function saveRule(id: string, patch: Partial<AppRule>) {
    await nook.saveSettings({ autocomplete: withAppRule(ac, id, { ...appRule(ac, id), ...patch }) });
  }

  // Nooit stilletjes naar de cloud: het externe brein kies je pas na een tweede klik.
  async function chooseEngine(engine: "local" | "brain") {
    if (engine === "brain" && !nook.info?.brainLocal && !confirmBrain) {
      confirmBrain = true;
      return;
    }
    confirmBrain = false;
    await save({ engine });
  }

  function statusLine(st: AutocompleteStatus | null): string {
    switch (st?.state) {
      case "ready": return st.local ? tr("Aan · {engine}", "On · {engine}", { engine: st.engine }) : tr("Aan · {engine} (extern)", "On · {engine} (external)", { engine: st.engine });
      case "checking": return tr("Model zoeken…", "Looking for a model…");
      case "paused": return tr("Gepauzeerd", "Paused");
      case "noModel": return tr("Nog geen model", "No model yet");
      case "unsupported": return tr("Kan hier niet", "Not possible here");
      default: return tr("Uit", "Off");
    }
  }

  // Een app staat aan als zijn eigen schakelaar aan staat, of "Standaard" en niet standaard uit.
  function appOn(id: string): boolean {
    const rule = appRule(ac, id);
    if (rule.enabled !== "inherit") return rule.enabled === "on";
    return ac.enabledByDefault && !offByDefault(id, view?.offByDefault ?? []);
  }

  function addApp() {
    const id = newApp.trim();
    if (!id) return;
    const name = id.toLowerCase().endsWith(".exe") ? id : `${id}.exe`;
    saveRule(name, { enabled: "off" });
    newApp = "";
  }

  const ruleApps = $derived(Object.keys(ac.apps));
  const listedApps = $derived.by(() => {
    const seen = view?.seenApps ?? [];
    const extra = ruleApps.filter((id) => !seen.some((a) => a.id.toLowerCase().replace(/\.exe$/, "") === id.toLowerCase().replace(/\.exe$/, "")));
    return [...seen, ...extra.map((id) => ({ id, name: id.replace(/\.exe$/i, "") }))];
  });

  const tri: { id: TriState; title: string }[] = $derived([
    { id: "inherit", title: tr("Standaard", "Default") },
    { id: "on", title: tr("Aan", "On") },
    { id: "off", title: tr("Uit", "Off") },
  ]);

  function appName(id: string): string {
    return view?.seenApps.find((a) => a.id === id)?.name ?? id.replace(/\.exe$/i, "");
  }

  function minutes(m: number): string {
    const total = Math.round(m);
    return total >= 60 ? tr("{h} u {m} min", "{h} h {m} min", { h: Math.floor(total / 60), m: total % 60 }) : tr("{m} min", "{m} min", { m: total });
  }

  const keyLabel = (k: string) => (k === "" ? tr("Uit", "Off") : k);
</script>

<h2>{tr("Aanvullen", "Autocomplete")}</h2>

{#if !caps?.autocomplete}
  <p class="muted">{caps?.notes?.autocomplete ?? tr("Aanvullen in elke app kan (nog) alleen op Windows.", "Autocomplete in every app only works on Windows (for now).")}</p>
  <p class="faint note">{tr("De Testen-tab werkt wel: probeer daar hoe Nook je zinnen aanvult met je eigen model.", "The Try it tab does work: try there how Nook completes your sentences with your own model.")}</p>
{/if}

<div class="tabs">
  {#each tabs as t (t.id)}<button class:on={tab === t.id} onclick={() => (tab = t.id)}>{t.title}</button>{/each}
</div>

{#if tab === "general"}
  <div class="group">
    <label class="row">
      <span>
        <strong>{tr("Zinnen aanvullen terwijl je typt", "Complete sentences as you type")}</strong><br />
        <small class="faint">
          {tr(
            "{word} neemt het volgende woord, {all} alles. Doortypen wat er staat houdt de rest; elke andere toets stuurt het weg.",
            "{word} takes the next word, {all} everything. Typing what's there keeps the rest; any other key dismisses it.",
            { word: ac.acceptWord || "Tab", all: ac.acceptAll || "Shift+Tab" },
          )}
        </small>
      </span>
      <input type="checkbox" checked={ac.enabled} disabled={!caps?.autocomplete} onchange={(e) => save({ enabled: e.currentTarget.checked })} />
    </label>
    {#if caps?.autocomplete && ac.enabled}
      <div class="row">
        <span>
          {statusLine(status)}
          {#if status?.detail}<br /><small class={status.state === "noModel" ? "err" : "faint"}>{status.detail}</small>{/if}
        </span>
        {#if view?.paused}
          <button onclick={async () => (view = await autocomplete.resume())}>{tr("Hervat", "Resume")}</button>
        {:else}
          <span class="inline">
            <button onclick={async () => (view = await autocomplete.pause(60))}>{tr("Pauzeer een uur", "Pause for an hour")}</button>
            <button onclick={async () => (view = await autocomplete.pause(null))}>{tr("Pauzeer", "Pause")}</button>
          </span>
        {/if}
      </div>
    {/if}
  </div>
  <p class="faint note">
    {tr(
      "Terwijl je typt stelt een model op deze computer voor hoe je zin verdergaat, als grijze tekst bij je cursor. Geen woordlimiet, geen abonnement, niets gaat je computer uit.",
      "As you type, a model on this computer suggests how your sentence goes on, as gray text at your cursor. No word limit, no subscription, nothing leaves your computer.",
    )}
  </p>

  <h3>{tr("Model", "Model")}</h3>
  <div class="group">
    <label class="row">
      <span>{tr("Een model op deze computer", "A model on this computer")}<br /><small class="faint">{tr("Ollama of LM Studio. Wat je typt blijft op deze computer.", "Ollama or LM Studio. What you type stays on this computer.")}</small></span>
      <input type="radio" name="engine" checked={ac.engine === "local"} onchange={() => chooseEngine("local")} />
    </label>
    {#if ac.engine === "local"}
      <label class="row">
        <span>{tr("Server", "Server")}</span>
        <select value={ac.localServer} onchange={(e) => save({ localServer: e.currentTarget.value as AutocompleteSettings["localServer"] })}>
          <option value="auto">{tr("Automatisch", "Automatic")}</option>
          <option value="ollama">Ollama</option>
          <option value="lmstudio">LM Studio</option>
        </select>
      </label>
      <label class="row">
        <span>{tr("Model", "Model")}<br /><small class="faint">{tr("Automatisch kiest het model van je brein als dat lokaal is, anders een klein chatmodel.", "Automatic picks your brain's model if it's local, otherwise a small chat model.")}</small></span>
        <select value={ac.model} onchange={(e) => save({ model: e.currentTarget.value })}>
          <option value="">{tr("Automatisch", "Automatic")}</option>
          {#each models as m (m)}<option value={m}>{m}</option>{/each}
          {#if ac.model && !models.includes(ac.model)}<option value={ac.model}>{ac.model}</option>{/if}
        </select>
      </label>
      {#if modelError}<p class="err note">{modelError} {tr("Installeer een lokaal model bij Instellingen › Brein.", "Install a local model under Settings › Brain.")}</p>{/if}
    {/if}
    <label class="row">
      <span>
        {tr("Het brein uit Instellingen › Brein", "The brain from Settings › Brain")}<br />
        <small class="faint">{nook.info?.brainLabel}{nook.info?.brainLocal ? "" : " — " + tr("extern: wat je typt gaat dan naar die dienst.", "external: what you type then goes to that service.")}</small>
      </span>
      <input type="radio" name="engine" checked={ac.engine === "brain"} onchange={() => chooseEngine("brain")} />
    </label>
    {#if confirmBrain}
      <div class="row confirm">
        <span>{tr("Wat je typt, in elke app, gaat dan naar {brain}. Wachtwoordvelden nooit.", "What you type, in every app, then goes to {brain}. Password fields never do.", { brain: nook.info?.brainLabel ?? "" })}</span>
        <span class="inline">
          <button class="primary" onclick={() => chooseEngine("brain")}>{tr("Ja, gebruik het externe brein", "Yes, use the external brain")}</button>
          <button onclick={() => { confirmBrain = false; load(); }}>{tr("Nee", "No")}</button>
        </span>
      </div>
    {/if}
  </div>

  <h3>{tr("Voorstellen", "Suggestions")}</h3>
  <div class="group">
    <label class="row">
      <span>{tr("Hoogstens {n} woorden", "At most {n} words", { n: ac.maxWords })}</span>
      <input type="range" min="1" max="20" value={ac.maxWords} onchange={(e) => save({ maxWords: Number(e.currentTarget.value) })} />
    </label>
    <label class="row">
      <span>{tr("Hoe gretig", "How eager")}<br /><small class="faint">{tr("Voorzichtig … Gretig", "Careful … Eager")}</small></span>
      <input type="range" min="0" max="1" step="0.05" value={ac.eagerness} onchange={(e) => save({ eagerness: Number(e.currentTarget.value) })} />
    </label>
    <label class="row">
      <span>{tr("Wachten na een toets: {ms} ms", "Wait after a key: {ms} ms", { ms: ac.delayMilliseconds })}</span>
      <input type="range" min="20" max="400" step="10" value={ac.delayMilliseconds} onchange={(e) => save({ delayMilliseconds: Number(e.currentTarget.value) })} />
    </label>
    <label class="row">
      <span>{tr("Midden in een regel", "In the middle of a line")}<br /><small class="faint">{tr("Ook voorstellen als er al tekst achter de cursor staat. Een voorstel stopt waar die tekst begint.", "Also suggest when there's already text after the cursor. A suggestion stops where that text begins.")}</small></span>
      <input type="checkbox" checked={ac.midLine} onchange={(e) => save({ midLine: e.currentTarget.checked })} />
    </label>
    <label class="row">
      <span>{tr("Spatie meenemen na een woord", "Include the space after a word")}</span>
      <input type="checkbox" checked={ac.trailingSpace} onchange={(e) => save({ trailingSpace: e.currentTarget.checked })} />
    </label>
    <label class="row">
      <span>{tr("Leestekens meenemen met een woord", "Include punctuation with a word")}</span>
      <input type="checkbox" checked={ac.punctuationWithWord} onchange={(e) => save({ punctuationWithWord: e.currentTarget.checked })} />
    </label>
  </div>

  <h3>{tr("Toetsen", "Keys")}</h3>
  <div class="group">
    <label class="row">
      <span>{tr("Volgende woord", "Next word")}</span>
      <select value={ac.acceptWord} onchange={(e) => save({ acceptWord: e.currentTarget.value })}>
        {#each view?.acceptKeys ?? [] as k (k)}<option value={k}>{keyLabel(k)}</option>{/each}
      </select>
    </label>
    <label class="row">
      <span>{tr("Alles", "Everything")}</span>
      <select value={ac.acceptAll} onchange={(e) => save({ acceptAll: e.currentTarget.value })}>
        {#each view?.acceptKeys ?? [] as k (k)}<option value={k}>{keyLabel(k)}</option>{/each}
        <option value="">{tr("Uit", "Off")}</option>
      </select>
    </label>
    <label class="row">
      <span>Escape</span>
      <select value={ac.escape} onchange={(e) => save({ escape: e.currentTarget.value as AutocompleteSettings["escape"] })}>
        <option value="dismiss">{tr("Voorstel wegsturen", "Dismiss the suggestion")}</option>
        <option value="pauseBriefly">{tr("Ook 10 seconden pauzeren", "Also pause for 10 seconds")}</option>
        <option value="offUntilAppSwitch">{tr("Uit in deze app tot je wisselt", "Off in this app until you switch")}</option>
      </select>
    </label>
  </div>
  <p class="faint note">{tr("De toetsen worden alleen opgevangen terwijl er een voorstel staat; anders gaan ze gewoon naar de app.", "The keys are only caught while a suggestion is showing; otherwise they go to the app as usual.")}</p>
{:else if tab === "apps"}
  <div class="group">
    <label class="row">
      <span>{tr("In elke app", "In every app")}<br /><small class="faint">{tr("Uit: alleen in apps die je hieronder aanzet.", "Off: only in apps you turn on below.")}</small></span>
      <input type="checkbox" checked={ac.enabledByDefault} onchange={(e) => save({ enabledByDefault: e.currentTarget.checked })} />
    </label>
  </div>

  <h3>{tr("Apps", "Apps")}</h3>
  <div class="group">
    {#if listedApps.length === 0}
      <p class="faint note">{tr("Nog geen apps gezien. Typ in een app terwijl aanvullen aan staat; hij verschijnt dan hier.", "No apps seen yet. Type in an app while autocomplete is on; it then shows up here.")}</p>
    {/if}
    {#each listedApps as a (a.id)}
      {@const rule = appRule(ac, a.id)}
      <div class="row">
        <button class="ghost appname" onclick={() => (openApp = openApp === a.id ? null : a.id)}>
          {a.name}
          <small class="faint">
            {a.id}{offByDefault(a.id, view?.offByDefault ?? []) ? " · " + tr("Standaard uit", "Off by default") : ""}{rule.instructions.trim() ? " · " + tr("Met eigen uitleg", "With its own instructions") : ""}
          </small>
        </button>
        <input type="checkbox" checked={appOn(a.id)} onchange={(e) => saveRule(a.id, { enabled: e.currentTarget.checked ? "on" : "off" })} />
      </div>
      {#if openApp === a.id}
        <div class="detail">
          <label class="row">
            <span>{tr("Voorstellen", "Suggestions")}</span>
            <select value={rule.enabled} onchange={(e) => saveRule(a.id, { enabled: e.currentTarget.value as TriState })}>
              {#each tri as t (t.id)}<option value={t.id}>{t.title}</option>{/each}
            </select>
          </label>
          <label class="row">
            <span>{tr("Midden in een regel", "In the middle of a line")}</span>
            <select value={rule.midLine} onchange={(e) => saveRule(a.id, { midLine: e.currentTarget.value as TriState })}>
              {#each tri as t (t.id)}<option value={t.id}>{t.title}</option>{/each}
            </select>
          </label>
          <label class="row">
            <span>{tr("Tab aan de app laten", "Leave Tab to the app")}</span>
            <input type="checkbox" checked={rule.leaveTab} onchange={(e) => saveRule(a.id, { leaveTab: e.currentTarget.checked })} />
          </label>
          <label class="column">
            <span>{tr("Extra uitleg voor deze app (bijv. kort en los voor Slack)", "Extra instructions for this app (e.g. short and casual for Slack)")}</span>
            <textarea rows="2" value={rule.instructions} onchange={(e) => saveRule(a.id, { instructions: e.currentTarget.value })}></textarea>
          </label>
          <button onclick={() => saveRule(a.id, { enabled: "inherit", midLine: "inherit", leaveTab: false, instructions: "" })}>{tr("Standaard", "Default")}</button>
        </div>
      {/if}
    {/each}
    <div class="row">
      <input placeholder={tr("App toevoegen, bijv. Slack.exe", "Add an app, e.g. Slack.exe")} bind:value={newApp} onkeydown={(e) => e.key === "Enter" && addApp()} />
      <button onclick={addApp}>{tr("Voeg toe", "Add")}</button>
    </div>
  </div>
  <p class="faint note">
    {tr(
      "Zet de schakelaar uit voor apps waarin je geen voorstellen wilt. Terminals, code-editors en wachtwoordmanagers staan standaard uit ({apps}). Klik op een app voor eigen uitleg en Tab.",
      "Turn the switch off for apps where you don't want suggestions. Terminals, code editors and password managers are off by default ({apps}). Click an app for its own instructions and Tab.",
      { apps: (view?.offByDefault ?? []).join(", ") },
    )}
  </p>
  <p class="faint note">{tr("Websites: eigen regels per website komen nog; Nook ziet op Windows het adres van de browser nog niet.", "Websites: rules per website are coming; on Windows Nook can't see the browser's address yet.")}</p>
{:else if tab === "style"}
  <h3>{tr("Wat het model weet", "What the model knows")}</h3>
  <div class="group">
    <label class="row">
      <span>{tr("App en venster", "App and window")}<br /><small class="faint">{tr("De naam van de app en de venstertitel.", "The app's name and the window title.")}</small></span>
      <input type="checkbox" checked={ac.windowContext} onchange={(e) => save({ windowContext: e.currentTarget.checked })} />
    </label>
    <label class="row">
      <span>{tr("Je geheugen", "Your memory")}<br /><small class="faint">{tr("Wat Nook over je onthoudt: je naam, je werk, de mensen om je heen. Zo vult hij namen en feiten goed in.", "What Nook remembers about you: your name, your work, the people around you. That way it fills in names and facts correctly.")}</small></span>
      <input type="checkbox" checked={ac.memoryContext} onchange={(e) => save({ memoryContext: e.currentTarget.checked })} />
    </label>
    <label class="row">
      <span>{tr("Het klembord", "The clipboard")}<br /><small class="faint">{tr("Wat je net kopieerde (tot vijf minuten). Wachtwoorden uit een wachtwoordmanager worden overgeslagen.", "What you just copied (up to five minutes). Passwords from a password manager are skipped.")}</small></span>
      <input type="checkbox" checked={ac.clipboardContext} onchange={(e) => save({ clipboardContext: e.currentTarget.checked })} />
    </label>
  </div>
  <p class="faint note">
    {tr(
      "Alles blijft op deze computer: de tekst gaat alleen naar het model hier en wordt niet bewaard. Wachtwoordvelden worden nooit gelezen, en in apps met meer rechten en op het beveiligde bureaublad doet Nook niets. Iets dat op een kaartnummer, IBAN, BSN of sleutel lijkt wordt eerst weggehaald.",
      "Everything stays on this computer: the text only goes to the model here and isn't kept. Password fields are never read, and Nook does nothing in apps with more rights or on the secure desktop. Anything that looks like a card number, IBAN, social security number or key is removed first.",
    )}
  </p>

  <h3>{tr("Jouw stijl", "Your style")}</h3>
  <div class="group">
    <label class="column">
      <span>{tr("Over jou en hoe je schrijft", "About you and how you write")}</span>
      <textarea rows="3" placeholder={tr("Bijvoorbeeld: Ik ben Anna, ik werk bij een reisbureau. Ik schrijf kort en informeel, in het Nederlands.", "For example: I'm Anna, I work at a travel agency. I write short and informal, in English.")} value={ac.instructions} onchange={(e) => save({ instructions: e.currentTarget.value })}></textarea>
    </label>
  </div>

  <h3>{tr("Emoji", "Emoji")}</h3>
  <div class="group">
    <label class="row">
      <span>{tr("Emoji met een dubbele punt", "Emoji with a colon")}<br /><small class="faint">{tr("Typ : aan het begin van een woord voor emoji die bij je tekst passen, of zoek verder: :lach, :heart, :duim.", "Type : at the start of a word for emoji that fit your text, or search further: :laugh, :heart, :thumbs.")}</small></span>
      <input type="checkbox" checked={ac.emoji} onchange={(e) => save({ emoji: e.currentTarget.checked })} />
    </label>
    <label class="row">
      <span>{tr("Huidskleur", "Skin tone")}</span>
      <select value={String(ac.skinTone)} onchange={(e) => save({ skinTone: Number(e.currentTarget.value) })}>
        <option value="0">👍 {tr("Geel", "Yellow")}</option>
        <option value="1">👍🏻</option>
        <option value="2">👍🏼</option>
        <option value="3">👍🏽</option>
        <option value="4">👍🏾</option>
        <option value="5">👍🏿</option>
      </select>
    </label>
    <label class="row">
      <span>{tr("Personen in emoji", "People in emoji")}</span>
      <select value={String(ac.emojiGender)} onchange={(e) => save({ emojiGender: Number(e.currentTarget.value) })}>
        <option value="0">🤷 {tr("Neutraal", "Neutral")}</option>
        <option value="1">🤷‍♀️ {tr("Vrouw", "Woman")}</option>
        <option value="2">🤷‍♂️ {tr("Man", "Man")}</option>
      </select>
    </label>
    <label class="row">
      <span>{tr("Emoji voor emoticons", "Emoji for emoticons")}<br /><small class="faint">{tr("Typ :-) of <3 en Tab zet de emoji ervoor in de plaats.", "Type :-) or <3 and Tab puts the emoji in its place.")}</small></span>
      <input type="checkbox" checked={ac.emoticons} onchange={(e) => save({ emoticons: e.currentTarget.checked })} />
    </label>
  </div>

  <h3>{tr("Spelling", "Spelling")}</h3>
  <div class="group">
    <label class="row">
      <span>{tr("Brits of Amerikaans, zoals jij schrijft", "British or American, the way you write")}<br /><small class="faint">{tr("Suggesties volgen je eigen Engelse spelling: colour of color, organise of organize.", "Suggestions follow your own English spelling: colour or color, organise or organize.")}</small></span>
      <input type="checkbox" checked={ac.matchSpelling} onchange={(e) => save({ matchSpelling: e.currentTarget.checked })} />
    </label>
  </div>

  <h3>{tr("Nog niet op Windows", "Not on Windows yet")}</h3>
  <p class="faint note">
    {tr(
      "Wat er op je scherm staat, leren van wat je schrijft, typfouten verbeteren, andere woorden kiezen en het gedrag op batterij komen later.",
      "What's on your screen, learning from what you write, fixing typos, choosing other words and behavior on battery come later.",
    )}
  </p>
{:else if tab === "playground"}
  <Playground />
{:else if tab === "stats" && view}
  {@const st = view.stats}
  {#if st.total.takes === 0}
    <p class="faint note">{tr("Nog niets aangevuld. Typ in een app en neem een voorstel met Tab.", "Nothing completed yet. Type in an app and take a suggestion with Tab.")}</p>
  {/if}
  <div class="tiles">
    <div class="tile"><small class="faint">{tr("Vandaag", "Today")}</small><strong>{st.today.takes}×</strong><small>{tr("{n} woorden", "{n} words", { n: st.today.words })}</small></div>
    <div class="tile"><small class="faint">{tr("Deze week", "This week")}</small><strong>{st.week.takes}×</strong><small>{tr("{n} woorden", "{n} words", { n: st.week.words })}</small></div>
    <div class="tile"><small class="faint">{tr("Totaal", "Total")}</small><strong>{st.total.takes}×</strong><small>{tr("{n} woorden", "{n} words", { n: st.total.words })}</small></div>
    <div class="tile"><small class="faint">{tr("Voorstellen genomen", "Suggestions taken")}</small><strong>{Math.round(st.acceptance * 100)}%</strong><small>{tr("{taken} van {shown}", "{taken} of {shown}", { taken: st.total.accepted, shown: st.total.shown })}</small></div>
  </div>
  <h3>{tr("Details", "Details")}</h3>
  <div class="group">
    <div class="row"><span>{tr("Typtijd bespaard", "Typing time saved")}</span><span>{minutes(st.minutesSaved)}</span></div>
    <div class="row"><span>{tr("Tekens ingevuld", "Characters filled in")}</span><span>{st.total.characters}</span></div>
    <div class="row"><span>{tr("Reeks", "Streak")}</span><span>{tr("{n} dagen op rij", "{n} days in a row", { n: st.streak })}</span></div>
  </div>
  {#if st.topApps.length}
    <h3>{tr("Waar je het meest aanvult", "Where you complete the most")}</h3>
    <div class="group">
      {#each st.topApps as [id, count] (id)}
        <div class="row"><span>{appName(id)}</span><span class="faint">{count.takes}× · {tr("{n} woorden", "{n} words", { n: count.words })}</span></div>
      {/each}
    </div>
  {/if}
  <p class="faint note">{tr("Nook telt alleen hoe vaak: nooit wat je typte.", "Nook only counts how often: never what you typed.")}</p>
  {#if confirmReset}
    <div class="inline">
      <span>{tr("Alle statistiek op nul zetten?", "Reset all statistics to zero?")}</span>
      <button class="primary" onclick={async () => { view = await autocomplete.resetStats(); confirmReset = false; }}>{tr("Zet op nul", "Reset")}</button>
      <button onclick={() => (confirmReset = false)}>{tr("Nee", "No")}</button>
    </div>
  {:else}
    <button onclick={() => (confirmReset = true)}>{tr("Zet op nul", "Reset")}</button>
  {/if}
{/if}

<style>
  .tabs { display: inline-flex; gap: 2px; background: var(--field); border: 1px solid var(--line); border-radius: 10px; padding: 2px; margin-bottom: 8px; flex-wrap: wrap; }
  .tabs button { border: none; background: none; color: var(--text2); padding: 4px 14px; }
  .tabs button.on { background: var(--smoke); color: var(--paper); }
  .column { display: flex; flex-direction: column; gap: 6px; padding: 10px 0; }
  .column textarea { width: 100%; box-sizing: border-box; }
  .detail { padding: 4px 0 10px 14px; border-bottom: 1px solid var(--line); }
  .appname { text-align: left; display: flex; flex-direction: column; align-items: flex-start; padding: 0; }
  .tiles { display: grid; grid-template-columns: repeat(auto-fill, minmax(140px, 1fr)); gap: 8px; margin-top: 12px; }
  .tile { display: flex; flex-direction: column; gap: 2px; background: var(--field); border: 1px solid var(--line); border-radius: var(--radius); padding: 10px 12px; }
  .tile strong { font-size: 20px; }
</style>
