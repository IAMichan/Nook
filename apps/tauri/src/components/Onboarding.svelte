<script lang="ts">
  // De eerste keer: drie stappen (brein, wat Nook mag zien, koppelingen). Elke stap is over te slaan en er gaat niets
  // aan zonder een klik. Klaar of Later zet `onboardingDone`, dan komt dit niet meer terug.
  import { api } from "../lib/api";
  import { brainApi, type SourceChoice } from "../lib/brain";
  import { nook } from "../lib/state.svelte";
  import ModelAdvice from "./ModelAdvice.svelte";

  let { onclose }: { onclose: () => void } = $props();
  let step = $state(0);
  let sources = $state<SourceChoice[]>([]);
  const steps = 3;
  const s = $derived(nook.settings!);
  const caps = $derived(nook.info?.capabilities);

  $effect(() => {
    if (step === 2) brainApi.sourceChoices().then((c) => (sources = c));
  });

  async function finish() {
    await nook.saveSettings({ onboardingDone: true });
    onclose();
  }

  function openSettings(section: string) {
    localStorage.setItem("settings.section", section);
    api.showMain("settings");
  }

  // De bronnen die Nook altijd heeft tellen niet als koppeling.
  const builtIn = new Set(["loops", "memory", "web", "charts", "mail", "system", "screen"]);
  const connected = $derived(sources.filter((c) => !builtIn.has(c.id)));
</script>

<div class="overlay" role="dialog" aria-modal="true" aria-label="Welkom bij Nook">
  <div class="card">
    <div class="head">
      <h2>Welkom bij Nook</h2>
      <span class="faint">Stap {step + 1} van {steps}</span>
    </div>
    <div class="progress"><div style="width: {((step + 1) / steps) * 100}%"></div></div>

    <div class="body">
      {#if step === 0}
        <h3>Waarmee denkt Nook?</h3>
        <p class="muted">Standaard op je eigen computer: er verlaat niets je computer. Nook stelt het model voor dat bij je geheugen past.</p>
        {#if nook.info?.brainReady}
          <p class="ok">✓ Klaar: {nook.info.brainLabel}</p>
        {/if}
        <ModelAdvice compact />
        <button class="link" onclick={() => openSettings("brain")}>Liever een externe AI (Claude, OpenAI, …)? Kies die bij Instellingen › Brein.</button>
      {:else if step === 1}
        <h3>Wat Nook mag zien</h3>
        <p class="muted">Alleen wat je hier toestaat. Je kunt het later altijd weer uitzetten bij Instellingen.</p>
        <div class="toggles">
          {#if caps?.screenReading}
            <label><input type="checkbox" checked={s.liveScreen} onchange={(e) => nook.saveSettings({ liveScreen: e.currentTarget.checked })} /> Je scherm lezen als je erom vraagt</label>
            <label><input type="checkbox" checked={s.screenWithEveryQuestion} onchange={(e) => nook.saveSettings({ screenWithEveryQuestion: e.currentTarget.checked })} /> Je scherm meesturen met elke vraag</label>
          {/if}
          <label><input type="checkbox" checked={s.useMemory} onchange={(e) => nook.saveSettings({ useMemory: e.currentTarget.checked })} /> Onthouden wat je Nook vertelt</label>
          <label><input type="checkbox" checked={s.learnFromChats} onchange={(e) => nook.saveSettings({ learnFromChats: e.currentTarget.checked })} /> Zelf leren van je correcties en plannen</label>
        </div>
      {:else}
        <h3>Koppelingen (optioneel)</h3>
        <p class="muted">Mail, agenda, GitHub, Notion en meer. Nu gekoppeld: {connected.length}. Je kunt later altijd koppelen of overslaan.</p>
        {#if connected.length}<p class="faint">{connected.map((c) => c.title).join(", ")}</p>{/if}
        <button onclick={() => openSettings("connections")}>Koppelingen bekijken</button>
        <p class="faint hint">Probeer daarna bijvoorbeeld: “Wat staat er vandaag in mijn agenda?”</p>
      {/if}
    </div>

    <div class="buttons">
      <button class="ghost" onclick={finish}>Later</button>
      <span class="spacer"></span>
      {#if step > 0}<button class="ghost" onclick={() => (step -= 1)}>Terug</button>{/if}
      <button class="primary" onclick={() => (step === steps - 1 ? finish() : (step += 1))}>{step === steps - 1 ? "Klaar" : "Volgende"}</button>
    </div>
  </div>
</div>

<style>
  .overlay { position: absolute; inset: 0; z-index: 30; display: flex; align-items: center; justify-content: center; background: color-mix(in srgb, var(--notch) 70%, transparent); padding: 16px; }
  .card { width: min(560px, 100%); max-height: 100%; overflow-y: auto; background: var(--graphite); border: 1px solid var(--line2); border-radius: 16px; padding: 18px 20px; display: flex; flex-direction: column; gap: 10px; }
  .head { display: flex; justify-content: space-between; align-items: baseline; }
  h2 { margin: 0; font-size: 18px; }
  h3 { margin: 0; font-size: 15px; }
  .progress { height: 3px; background: var(--line2); border-radius: 2px; overflow: hidden; }
  .progress div { height: 100%; background: var(--iris); transition: width 0.2s; }
  .body { display: flex; flex-direction: column; gap: 10px; min-height: 220px; }
  .body p { margin: 0; }
  .ok { color: var(--mint); }
  .toggles { display: flex; flex-direction: column; gap: 8px; }
  .toggles label { display: flex; gap: 8px; align-items: center; }
  .link { background: none; border: none; padding: 0; color: var(--text2); text-align: left; font-size: 12px; text-decoration: underline; }
  .hint { font-size: 12px; }
  .body > button { align-self: flex-start; }
  .buttons { display: flex; gap: 8px; align-items: center; }
  .spacer { flex: 1; }
</style>
