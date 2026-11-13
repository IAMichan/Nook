<script lang="ts">
  // Algemeen: taal, plek van de balk, kleur, energie, sneltoetsen.
  import { api } from "../../lib/api";
  import { nook, accentCss } from "../../lib/state.svelte";
  import { services, serviceEvents, type EnergyView } from "../../lib/services";
  import type { EnergyMode } from "../../lib/types";
  import { enable, disable, isEnabled } from "@tauri-apps/plugin-autostart";
  import ShortcutField from "../../components/ShortcutField.svelte";
  import { tr, APP_LANGUAGES, type AppLanguage } from "../../lib/i18n.svelte";

  // Shortcuts another app already holds: Rust says which after every change, Settings shows it at the row.
  let taken = $state<string[]>([]);
  $effect(() => {
    void s.shortcuts;
    // Registering happens on save; ask a moment later.
    const timer = setTimeout(() => api.shortcutProblems().then((p) => (taken = p)).catch(() => {}), 150);
    return () => clearTimeout(timer);
  });

  const s = $derived(nook.settings!);
  const accents = [0xf4f3f7, 0x8b7bff, 0x46e0a6, 0xffb84d, 0xff8a5b, 0x5ab8ff, 0xff6bb5];
  const shortcutNames = $derived<Record<string, string>>({
    chat: tr("Chatten", "Chat"), talk: tr("Praten", "Talk"), window: tr("Hoofdvenster", "Main window"), lookAlong: tr("Meekijken", "Look along"),
  });

  // Energy: one choice, what it means, and what Nook does right now.
  const energyModes: { id: EnergyMode; title: string; detail: string }[] = $derived([
    { id: "automatic", title: tr("Automatisch", "Automatic"), detail: tr("Nook doet een stap terug op de accu, als je computer warm of druk bezig is, en als je weg bent.", "Nook steps back on battery, when your computer is hot or busy, and when you are away.") },
    { id: "saver", title: tr("Zuinig", "Saver"), detail: tr("Altijd licht: het scherm wordt minder vaak gelezen en suggesties komen minder vaak. Fijn op een laptop die lang op de accu moet.", "Always light: the screen is read less often and suggestions come less often. Good for a laptop that has to last on battery.") },
    { id: "full", title: tr("Volle kracht", "Full power"), detail: tr("Nooit rustiger voor de accu of een drukke computer. Een warme computer krijgt nog wel even rust.", "Never slows down for the battery or a busy computer. A hot computer still gets a break.") },
  ]);
  let launchAtLogin = $state(false);
  $effect(() => {
    if (nook.info?.capabilities.desktop) isEnabled().then((v) => (launchAtLogin = v)).catch(() => {});
  });
  async function setLaunchAtLogin(on: boolean) {
    try {
      if (on) await enable(); else await disable();
    } catch {}
    launchAtLogin = await isEnabled().catch(() => !on);
  }
  let shortcutNote = $state("");
  async function repairShortcut() {
    shortcutNote = await api.repairStartMenuShortcut().then(() => tr("Snelkoppeling in het Startmenu gemaakt.", "Start menu shortcut created."), (e) => String(e));
  }
  let energy = $state<EnergyView | null>(null);
  $effect(() => {
    services.energyStatus().then((v) => (energy = v)).catch(() => {});
    const un = serviceEvents.onEnergy((v) => (energy = v));
    return () => {
      un.then((f) => f());
    };
  });
</script>

<h2>{tr("Algemeen", "General")}</h2>
<div class="group">
  <label class="row">
    <span>{tr("Taal van Nook", "Language")}</span>
    <select value={s.appLanguage} onchange={(e) => nook.saveSettings({ appLanguage: e.currentTarget.value as AppLanguage })}>
      {#each APP_LANGUAGES as lang (lang.code)}<option value={lang.code}>{lang.name}</option>{/each}
    </select>
  </label>
  <label class="row">
    <span>{tr("Taal van Nooks antwoorden", "Language of Nook's answers")}</span>
    <select value={s.language} onchange={(e) => nook.saveSettings({ language: e.currentTarget.value })}>
      {#each APP_LANGUAGES as lang (lang.code)}<option value={lang.code}>{lang.name}</option>{/each}
      <option value="auto">{tr("Taal van mijn vraag", "Language of my question")}</option>
    </select>
  </label>
  {#if nook.info?.capabilities.desktop}
    <label class="row">
      <span>{tr("Plek", "Position")}</span>
      <select value={s.placement} onchange={(e) => nook.saveSettings({ placement: e.currentTarget.value as "top" | "floating" })}>
        <option value="top">{tr("Bovenaan het scherm", "At the top of the screen")}</option>
        <option value="floating">{tr("Zwevend op het scherm", "Floating on the screen")}</option>
      </select>
    </label>
    <label class="row"><span>{tr("Starten als ik inlog op de computer", "Open at login")}</span><input type="checkbox" checked={launchAtLogin} onchange={(e) => setLaunchAtLogin(e.currentTarget.checked)} /></label>
    {#if nook.info.capabilities.os === "windows"}
      <div class="row">
        <span>{tr("Snelkoppeling in het Startmenu", "Start menu shortcut")}{#if shortcutNote} <small>{shortcutNote}</small>{/if}</span>
        <button onclick={repairShortcut}>{tr("Herstellen", "Repair")}</button>
      </div>
    {/if}
    <label class="row">
      <span>{tr("Lokaal brein zelf starten", "Start the local brain myself")}<br /><small class="faint">{tr("Is Ollama of LM Studio geïnstalleerd maar niet gestart? Dan start Nook hem op de achtergrond.", "Ollama or LM Studio installed but not running? Then Nook starts it in the background.")}</small></span>
      <input type="checkbox" checked={s.startLocalBrain} onchange={(e) => nook.saveSettings({ startLocalBrain: e.currentTarget.checked })} />
    </label>
    <label class="row"><span>{tr("Groter paneel", "Larger panel")}</span><input type="checkbox" checked={s.panelLarge} onchange={(e) => nook.saveSettings({ panelLarge: e.currentTarget.checked })} /></label>
  {/if}
  <div class="row">
    <span>{tr("Kleur van Nook", "Nook's color")}</span>
    <div class="swatches">
      {#each accents as a (a)}
        <button class="swatch" class:on={s.accentHex === a} style="background:{accentCss(a)}" aria-label={tr("Kleur", "Color")} onclick={() => nook.saveSettings({ accentHex: a })}></button>
      {/each}
    </div>
  </div>
</div>
{#if nook.info?.capabilities.desktop}
  <h3>{tr("Energie", "Energy")}</h3>
  <div class="group">
    <label class="row">
      <span>{tr("Werk op de achtergrond", "Background work")}<br /><small class="faint">{tr("Scherm lezen, meedenken en meetings herkennen terwijl jij werkt. Wat je zelf vraagt gaat altijd op volle snelheid.", "Reading the screen, thinking along and spotting meetings while you work. Anything you ask for always runs at full speed.")}</small></span>
      <select value={s.energyMode} onchange={(e) => nook.saveSettings({ energyMode: e.currentTarget.value as EnergyMode })}>
        {#each energyModes as mode (mode.id)}<option value={mode.id}>{mode.title}</option>{/each}
      </select>
    </label>
    <p class="faint note">{energyModes.find((m) => m.id === s.energyMode)?.detail}</p>
    <div class="row">
      <span>{tr("Nu", "Right now")}</span>
      <span class="faint" class:light={energy && energy.plan.pace !== "full"}>{energy?.status ?? tr("Volle snelheid", "Full speed")}</span>
    </div>
    <p class="faint note">{tr("Nook werkt op de achtergrond zodat een antwoord direct klaar is: hij leest de tekst op je scherm, denkt mee en kijkt of je in een meeting zit. Dat kost een beetje stroom. Als Nook een stap terugdoet, leest een vraag het scherm alsnog meteen.", "Nook works in the background so an answer is ready right away: it reads the text on your screen, thinks along and checks whether you are in a meeting. That costs a little power. When Nook steps back, a question still reads the screen right away.")}</p>
  </div>
{/if}
{#if nook.info?.capabilities.globalShortcuts}
  <h3>{tr("Sneltoetsen", "Shortcuts")}</h3>
  <div class="group">
    {#each Object.entries(s.shortcuts) as [action, accel] (action)}
      <div class="row">
        <span>{shortcutNames[action] ?? action}</span>
        <ShortcutField value={accel} taken={taken.includes(action)} onchange={(next) => nook.saveSettings({ shortcuts: { ...s.shortcuts, [action]: next } })} />
      </div>
    {/each}
    <p class="faint note">{tr("Klik op een sneltoets en druk de nieuwe toetsen in. Is hij al bezet door een andere app, dan zie je dat hier meteen.", "Click a shortcut and press the new keys. If another app already uses it, you see that here right away.")}</p>
  </div>
{/if}
      

<style>
  small { font-size: 11px; line-height: 1.35; display: inline-block; max-width: 460px; }
  .light { color: var(--amber); }
</style>
