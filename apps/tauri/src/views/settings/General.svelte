<script lang="ts">
  // Algemeen: taal, plek van de balk, kleur, energie, sneltoetsen.
  import { nook, accentCss } from "../../lib/state.svelte";
  import { services, serviceEvents, type EnergyView } from "../../lib/services";
  import type { EnergyMode } from "../../lib/types";

  const s = $derived(nook.settings!);
  const accents = [0xf4f3f7, 0x8b7bff, 0x46e0a6, 0xffb84d, 0xff8a5b, 0x5ab8ff, 0xff6bb5];
  const shortcutNames: Record<string, string> = {
    chat: "Chatten", talk: "Praten", window: "Hoofdvenster", lookAlong: "Meekijken",
  };

  // Energy: one choice, what it means, and what Nook does right now.
  const energyModes: { id: EnergyMode; title: string; detail: string }[] = [
    { id: "automatic", title: "Automatisch", detail: "Nook doet een stap terug op de accu, als je computer warm of druk bezig is, en als je weg bent." },
    { id: "saver", title: "Zuinig", detail: "Altijd licht: het scherm wordt minder vaak gelezen en suggesties komen minder vaak. Fijn op een laptop die lang op de accu moet." },
    { id: "full", title: "Volle kracht", detail: "Nooit rustiger voor de accu of een drukke computer. Een warme computer krijgt nog wel even rust." },
  ];
  let energy = $state<EnergyView | null>(null);
  $effect(() => {
    services.energyStatus().then((v) => (energy = v)).catch(() => {});
    const un = serviceEvents.onEnergy((v) => (energy = v));
    return () => {
      un.then((f) => f());
    };
  });
</script>

<h2>Algemeen</h2>
<div class="group">
  <label class="row">
    <span>Taal van Nooks antwoorden</span>
    <select value={s.language} onchange={(e) => nook.saveSettings({ language: e.currentTarget.value })}>
      <option value="nl">Nederlands</option><option value="en">English</option><option value="de">Deutsch</option>
      <option value="fr">Français</option><option value="es">Español</option><option value="auto">Taal van mijn vraag</option>
    </select>
  </label>
  {#if nook.info?.capabilities.desktop}
    <label class="row">
      <span>Plek</span>
      <select value={s.placement} onchange={(e) => nook.saveSettings({ placement: e.currentTarget.value as "top" | "floating" })}>
        <option value="top">Bovenaan het scherm</option>
        <option value="floating">Zwevend op het scherm</option>
      </select>
    </label>
    <label class="row"><span>Groter paneel</span><input type="checkbox" checked={s.panelLarge} onchange={(e) => nook.saveSettings({ panelLarge: e.currentTarget.checked })} /></label>
  {/if}
  <div class="row">
    <span>Kleur van Nook</span>
    <div class="swatches">
      {#each accents as a (a)}
        <button class="swatch" class:on={s.accentHex === a} style="background:{accentCss(a)}" aria-label="Kleur" onclick={() => nook.saveSettings({ accentHex: a })}></button>
      {/each}
    </div>
  </div>
</div>
{#if nook.info?.capabilities.desktop}
  <h3>Energie</h3>
  <div class="group">
    <label class="row">
      <span>Werk op de achtergrond<br /><small class="faint">Scherm lezen, meedenken en meetings herkennen terwijl jij werkt. Wat je zelf vraagt gaat altijd op volle snelheid.</small></span>
      <select value={s.energyMode} onchange={(e) => nook.saveSettings({ energyMode: e.currentTarget.value as EnergyMode })}>
        {#each energyModes as mode (mode.id)}<option value={mode.id}>{mode.title}</option>{/each}
      </select>
    </label>
    <p class="faint note">{energyModes.find((m) => m.id === s.energyMode)?.detail}</p>
    <div class="row">
      <span>Nu</span>
      <span class="faint" class:light={energy && energy.plan.pace !== "full"}>{energy?.status ?? "Volle snelheid"}</span>
    </div>
    <p class="faint note">Nook werkt op de achtergrond zodat een antwoord direct klaar is: hij leest de tekst op je scherm, denkt mee en kijkt of je in een meeting zit. Dat kost een beetje stroom. Als Nook een stap terugdoet, leest een vraag het scherm alsnog meteen.</p>
  </div>
{/if}
{#if nook.info?.capabilities.globalShortcuts}
  <h3>Sneltoetsen</h3>
  <div class="group">
    {#each Object.entries(s.shortcuts) as [action, accel] (action)}
      <label class="row">
        <span>{shortcutNames[action] ?? action}</span>
        <input value={accel} onchange={(e) => nook.saveSettings({ shortcuts: { ...s.shortcuts, [action]: e.currentTarget.value } })} />
      </label>
    {/each}
    <p class="faint note">Schrijf als Alt+Space of CommandOrControl+Shift+K. Een toets die een andere app al gebruikt, wordt overgeslagen.</p>
  </div>
{/if}
      

<style>
  small { font-size: 11px; line-height: 1.35; display: inline-block; max-width: 460px; }
  .light { color: var(--amber); }
</style>
