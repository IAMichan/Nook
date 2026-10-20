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

  type Tab = "general" | "apps" | "style" | "playground" | "stats";
  const tabs: { id: Tab; title: string }[] = [
    { id: "general", title: "Algemeen" },
    { id: "apps", title: "Apps" },
    { id: "style", title: "Stijl en context" },
    { id: "playground", title: "Testen" },
    { id: "stats", title: "Statistiek" },
  ];
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
      case "ready": return `Aan · ${st.engine}${st.local ? "" : " (extern)"}`;
      case "checking": return "Model zoeken…";
      case "paused": return "Gepauzeerd";
      case "noModel": return "Nog geen model";
      case "unsupported": return "Kan hier niet";
      default: return "Uit";
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

  const tri: { id: TriState; title: string }[] = [
    { id: "inherit", title: "Standaard" },
    { id: "on", title: "Aan" },
    { id: "off", title: "Uit" },
  ];

  function appName(id: string): string {
    return view?.seenApps.find((a) => a.id === id)?.name ?? id.replace(/\.exe$/i, "");
  }

  function minutes(m: number): string {
    const total = Math.round(m);
    return total >= 60 ? `${Math.floor(total / 60)} u ${total % 60} min` : `${total} min`;
  }

  const keyLabel = (k: string) => (k === "" ? "Uit" : k);
</script>

<h2>Aanvullen</h2>

{#if !caps?.autocomplete}
  <p class="muted">{caps?.notes?.autocomplete ?? "Aanvullen in elke app kan (nog) alleen op Windows."}</p>
  <p class="faint note">De Testen-tab werkt wel: probeer daar hoe Nook je zinnen aanvult met je eigen model.</p>
{/if}

<div class="tabs">
  {#each tabs as t (t.id)}<button class:on={tab === t.id} onclick={() => (tab = t.id)}>{t.title}</button>{/each}
</div>

{#if tab === "general"}
  <div class="group">
    <label class="row">
      <span>
        <strong>Zinnen aanvullen terwijl je typt</strong><br />
        <small class="faint">
          {ac.acceptWord || "Tab"} neemt het volgende woord, {ac.acceptAll || "Shift+Tab"} alles. Doortypen wat er staat houdt de rest;
          elke andere toets stuurt het weg.
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
          <button onclick={async () => (view = await autocomplete.resume())}>Hervat</button>
        {:else}
          <span class="inline">
            <button onclick={async () => (view = await autocomplete.pause(60))}>Pauzeer een uur</button>
            <button onclick={async () => (view = await autocomplete.pause(null))}>Pauzeer</button>
          </span>
        {/if}
      </div>
    {/if}
  </div>
  <p class="faint note">
    Terwijl je typt stelt een model op deze computer voor hoe je zin verdergaat, als grijze tekst bij je cursor. Geen woordlimiet,
    geen abonnement, niets gaat je computer uit.
  </p>

  <h3>Model</h3>
  <div class="group">
    <label class="row">
      <span>Een model op deze computer<br /><small class="faint">Ollama of LM Studio. Wat je typt blijft op deze computer.</small></span>
      <input type="radio" name="engine" checked={ac.engine === "local"} onchange={() => chooseEngine("local")} />
    </label>
    {#if ac.engine === "local"}
      <label class="row">
        <span>Server</span>
        <select value={ac.localServer} onchange={(e) => save({ localServer: e.currentTarget.value as AutocompleteSettings["localServer"] })}>
          <option value="auto">Automatisch</option>
          <option value="ollama">Ollama</option>
          <option value="lmstudio">LM Studio</option>
        </select>
      </label>
      <label class="row">
        <span>Model<br /><small class="faint">Automatisch kiest het model van je brein als dat lokaal is, anders een klein chatmodel.</small></span>
        <select value={ac.model} onchange={(e) => save({ model: e.currentTarget.value })}>
          <option value="">Automatisch</option>
          {#each models as m (m)}<option value={m}>{m}</option>{/each}
          {#if ac.model && !models.includes(ac.model)}<option value={ac.model}>{ac.model}</option>{/if}
        </select>
      </label>
      {#if modelError}<p class="err note">{modelError} Installeer een lokaal model bij Instellingen › Brein.</p>{/if}
    {/if}
    <label class="row">
      <span>
        Het brein uit Instellingen › Brein<br />
        <small class="faint">{nook.info?.brainLabel}{nook.info?.brainLocal ? "" : " — extern: wat je typt gaat dan naar die dienst."}</small>
      </span>
      <input type="radio" name="engine" checked={ac.engine === "brain"} onchange={() => chooseEngine("brain")} />
    </label>
    {#if confirmBrain}
      <div class="row confirm">
        <span>Wat je typt, in elke app, gaat dan naar {nook.info?.brainLabel}. Wachtwoordvelden nooit.</span>
        <span class="inline">
          <button class="primary" onclick={() => chooseEngine("brain")}>Ja, gebruik het externe brein</button>
          <button onclick={() => { confirmBrain = false; load(); }}>Nee</button>
        </span>
      </div>
    {/if}
  </div>

  <h3>Voorstellen</h3>
  <div class="group">
    <label class="row">
      <span>Hoogstens {ac.maxWords} woorden</span>
      <input type="range" min="1" max="20" value={ac.maxWords} onchange={(e) => save({ maxWords: Number(e.currentTarget.value) })} />
    </label>
    <label class="row">
      <span>Hoe gretig<br /><small class="faint">Voorzichtig … Gretig</small></span>
      <input type="range" min="0" max="1" step="0.05" value={ac.eagerness} onchange={(e) => save({ eagerness: Number(e.currentTarget.value) })} />
    </label>
    <label class="row">
      <span>Wachten na een toets: {ac.delayMilliseconds} ms</span>
      <input type="range" min="20" max="400" step="10" value={ac.delayMilliseconds} onchange={(e) => save({ delayMilliseconds: Number(e.currentTarget.value) })} />
    </label>
    <label class="row">
      <span>Midden in een regel<br /><small class="faint">Ook voorstellen als er al tekst achter de cursor staat. Een voorstel stopt waar die tekst begint.</small></span>
      <input type="checkbox" checked={ac.midLine} onchange={(e) => save({ midLine: e.currentTarget.checked })} />
    </label>
    <label class="row">
      <span>Spatie meenemen na een woord</span>
      <input type="checkbox" checked={ac.trailingSpace} onchange={(e) => save({ trailingSpace: e.currentTarget.checked })} />
    </label>
    <label class="row">
      <span>Leestekens meenemen met een woord</span>
      <input type="checkbox" checked={ac.punctuationWithWord} onchange={(e) => save({ punctuationWithWord: e.currentTarget.checked })} />
    </label>
  </div>

  <h3>Toetsen</h3>
  <div class="group">
    <label class="row">
      <span>Volgende woord</span>
      <select value={ac.acceptWord} onchange={(e) => save({ acceptWord: e.currentTarget.value })}>
        {#each view?.acceptKeys ?? [] as k (k)}<option value={k}>{keyLabel(k)}</option>{/each}
      </select>
    </label>
    <label class="row">
      <span>Alles</span>
      <select value={ac.acceptAll} onchange={(e) => save({ acceptAll: e.currentTarget.value })}>
        {#each view?.acceptKeys ?? [] as k (k)}<option value={k}>{keyLabel(k)}</option>{/each}
        <option value="">Uit</option>
      </select>
    </label>
    <label class="row">
      <span>Escape</span>
      <select value={ac.escape} onchange={(e) => save({ escape: e.currentTarget.value as AutocompleteSettings["escape"] })}>
        <option value="dismiss">Voorstel wegsturen</option>
        <option value="pauseBriefly">Ook 10 seconden pauzeren</option>
        <option value="offUntilAppSwitch">Uit in deze app tot je wisselt</option>
      </select>
    </label>
  </div>
  <p class="faint note">De toetsen worden alleen opgevangen terwijl er een voorstel staat; anders gaan ze gewoon naar de app.</p>
{:else if tab === "apps"}
  <div class="group">
    <label class="row">
      <span>In elke app<br /><small class="faint">Uit: alleen in apps die je hieronder aanzet.</small></span>
      <input type="checkbox" checked={ac.enabledByDefault} onchange={(e) => save({ enabledByDefault: e.currentTarget.checked })} />
    </label>
  </div>

  <h3>Apps</h3>
  <div class="group">
    {#if listedApps.length === 0}
      <p class="faint note">Nog geen apps gezien. Typ in een app terwijl aanvullen aan staat; hij verschijnt dan hier.</p>
    {/if}
    {#each listedApps as a (a.id)}
      {@const rule = appRule(ac, a.id)}
      <div class="row">
        <button class="ghost appname" onclick={() => (openApp = openApp === a.id ? null : a.id)}>
          {a.name}
          <small class="faint">
            {a.id}{offByDefault(a.id, view?.offByDefault ?? []) ? " · Standaard uit" : ""}{rule.instructions.trim() ? " · Met eigen uitleg" : ""}
          </small>
        </button>
        <input type="checkbox" checked={appOn(a.id)} onchange={(e) => saveRule(a.id, { enabled: e.currentTarget.checked ? "on" : "off" })} />
      </div>
      {#if openApp === a.id}
        <div class="detail">
          <label class="row">
            <span>Voorstellen</span>
            <select value={rule.enabled} onchange={(e) => saveRule(a.id, { enabled: e.currentTarget.value as TriState })}>
              {#each tri as t (t.id)}<option value={t.id}>{t.title}</option>{/each}
            </select>
          </label>
          <label class="row">
            <span>Midden in een regel</span>
            <select value={rule.midLine} onchange={(e) => saveRule(a.id, { midLine: e.currentTarget.value as TriState })}>
              {#each tri as t (t.id)}<option value={t.id}>{t.title}</option>{/each}
            </select>
          </label>
          <label class="row">
            <span>Tab aan de app laten</span>
            <input type="checkbox" checked={rule.leaveTab} onchange={(e) => saveRule(a.id, { leaveTab: e.currentTarget.checked })} />
          </label>
          <label class="column">
            <span>Extra uitleg voor deze app (bijv. kort en los voor Slack)</span>
            <textarea rows="2" value={rule.instructions} onchange={(e) => saveRule(a.id, { instructions: e.currentTarget.value })}></textarea>
          </label>
          <button onclick={() => saveRule(a.id, { enabled: "inherit", midLine: "inherit", leaveTab: false, instructions: "" })}>Standaard</button>
        </div>
      {/if}
    {/each}
    <div class="row">
      <input placeholder="App toevoegen, bijv. Slack.exe" bind:value={newApp} onkeydown={(e) => e.key === "Enter" && addApp()} />
      <button onclick={addApp}>Voeg toe</button>
    </div>
  </div>
  <p class="faint note">
    Zet de schakelaar uit voor apps waarin je geen voorstellen wilt. Terminals, code-editors en wachtwoordmanagers staan standaard
    uit ({(view?.offByDefault ?? []).join(", ")}). Klik op een app voor eigen uitleg en Tab.
  </p>
  <p class="faint note">Websites: eigen regels per website komen nog; Nook ziet op Windows het adres van de browser nog niet.</p>
{:else if tab === "style"}
  <h3>Wat het model weet</h3>
  <div class="group">
    <label class="row">
      <span>App en venster<br /><small class="faint">De naam van de app en de venstertitel.</small></span>
      <input type="checkbox" checked={ac.windowContext} onchange={(e) => save({ windowContext: e.currentTarget.checked })} />
    </label>
    <label class="row">
      <span>Je geheugen<br /><small class="faint">Wat Nook over je onthoudt: je naam, je werk, de mensen om je heen. Zo vult hij namen en feiten goed in.</small></span>
      <input type="checkbox" checked={ac.memoryContext} onchange={(e) => save({ memoryContext: e.currentTarget.checked })} />
    </label>
    <label class="row">
      <span>Het klembord<br /><small class="faint">Wat je net kopieerde (tot vijf minuten). Wachtwoorden uit een wachtwoordmanager worden overgeslagen.</small></span>
      <input type="checkbox" checked={ac.clipboardContext} onchange={(e) => save({ clipboardContext: e.currentTarget.checked })} />
    </label>
  </div>
  <p class="faint note">
    Alles blijft op deze computer: de tekst gaat alleen naar het model hier en wordt niet bewaard. Wachtwoordvelden worden nooit
    gelezen, en in apps met meer rechten en op het beveiligde bureaublad doet Nook niets. Iets dat op een kaartnummer, IBAN, BSN of
    sleutel lijkt wordt eerst weggehaald.
  </p>

  <h3>Jouw stijl</h3>
  <div class="group">
    <label class="column">
      <span>Over jou en hoe je schrijft</span>
      <textarea rows="3" placeholder="Bijvoorbeeld: Ik ben Anna, ik werk bij een reisbureau. Ik schrijf kort en informeel, in het Nederlands." value={ac.instructions} onchange={(e) => save({ instructions: e.currentTarget.value })}></textarea>
    </label>
  </div>

  <h3>Emoji</h3>
  <div class="group">
    <label class="row">
      <span>Emoji met een dubbele punt<br /><small class="faint">Typ : aan het begin van een woord voor emoji die bij je tekst passen, of zoek verder: :lach, :heart, :duim.</small></span>
      <input type="checkbox" checked={ac.emoji} onchange={(e) => save({ emoji: e.currentTarget.checked })} />
    </label>
    <label class="row">
      <span>Huidskleur</span>
      <select value={String(ac.skinTone)} onchange={(e) => save({ skinTone: Number(e.currentTarget.value) })}>
        <option value="0">👍 Geel</option>
        <option value="1">👍🏻</option>
        <option value="2">👍🏼</option>
        <option value="3">👍🏽</option>
        <option value="4">👍🏾</option>
        <option value="5">👍🏿</option>
      </select>
    </label>
  </div>

  <h3>Nog niet op Windows</h3>
  <p class="faint note">
    Wat er op je scherm staat, leren van wat je schrijft, typfouten verbeteren, andere woorden kiezen en het gedrag op batterij
    komen later.
  </p>
{:else if tab === "playground"}
  <Playground />
{:else if tab === "stats" && view}
  {@const st = view.stats}
  {#if st.total.takes === 0}
    <p class="faint note">Nog niets aangevuld. Typ in een app en neem een voorstel met Tab.</p>
  {/if}
  <div class="tiles">
    <div class="tile"><small class="faint">Vandaag</small><strong>{st.today.takes}×</strong><small>{st.today.words} woorden</small></div>
    <div class="tile"><small class="faint">Deze week</small><strong>{st.week.takes}×</strong><small>{st.week.words} woorden</small></div>
    <div class="tile"><small class="faint">Totaal</small><strong>{st.total.takes}×</strong><small>{st.total.words} woorden</small></div>
    <div class="tile"><small class="faint">Voorstellen genomen</small><strong>{Math.round(st.acceptance * 100)}%</strong><small>{st.total.accepted} van {st.total.shown}</small></div>
  </div>
  <h3>Details</h3>
  <div class="group">
    <div class="row"><span>Typtijd bespaard</span><span>{minutes(st.minutesSaved)}</span></div>
    <div class="row"><span>Tekens ingevuld</span><span>{st.total.characters}</span></div>
    <div class="row"><span>Reeks</span><span>{st.streak} dagen op rij</span></div>
  </div>
  {#if st.topApps.length}
    <h3>Waar je het meest aanvult</h3>
    <div class="group">
      {#each st.topApps as [id, count] (id)}
        <div class="row"><span>{appName(id)}</span><span class="faint">{count.takes}× · {count.words} woorden</span></div>
      {/each}
    </div>
  {/if}
  <p class="faint note">Nook telt alleen hoe vaak: nooit wat je typte.</p>
  {#if confirmReset}
    <div class="inline">
      <span>Alle statistiek op nul zetten?</span>
      <button class="primary" onclick={async () => { view = await autocomplete.resetStats(); confirmReset = false; }}>Zet op nul</button>
      <button onclick={() => (confirmReset = false)}>Nee</button>
    </div>
  {:else}
    <button onclick={() => (confirmReset = true)}>Zet op nul</button>
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
