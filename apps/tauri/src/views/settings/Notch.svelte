<script lang="ts">
  // General › Bar & windows (the Mac's Notch & windows, `notchSection`): everywhere Nook shows in one group, in the
  // Mac's order (place, screen, hiding when idle), then how it behaves in meetings and while you share your screen.
  // Windows has no notch: the bar's size, starting with the computer and the Start menu shortcut are its own rows.
  import { api } from "../../lib/api";
  import { nook } from "../../lib/state.svelte";
  import { enable, disable, isEnabled } from "@tauri-apps/plugin-autostart";
  import { tr } from "../../lib/i18n.svelte";
  import Voice from "./Voice.svelte";

  const s = $derived(nook.settings!);
  const caps = $derived(nook.info?.capabilities);
  let launchAtLogin = $state(false);
  $effect(() => {
    if (caps?.desktop) isEnabled().then((v) => (launchAtLogin = v)).catch(() => {});
  });
  async function setLaunchAtLogin(on: boolean) {
    try {
      if (on) await enable(); else await disable();
    } catch {}
    launchAtLogin = await isEnabled().catch(() => !on);
  }
  // The connected screens, for the screen menu (a chosen one that is not connected stays in the list).
  let screens = $state<string[]>([]);
  $effect(() => {
    if (caps?.desktop) api.screenNames().then((n) => (screens = n)).catch(() => {});
  });
  let shortcutNote = $state("");
  async function repairShortcut() {
    shortcutNote = await api.repairStartMenuShortcut().then(() => tr("Snelkoppeling in het Startmenu gemaakt.", "Start menu shortcut created."), (e) => String(e));
  }
</script>

{#if caps?.desktop}
  <h3>{tr("Waar Nook staat", "Where Nook shows")}</h3>
  <div class="group">
    <label class="row">
      <span>{tr("Nook in de balk", "Nook in the bar")}<br /><small>{tr("Uit: Nook blijft uit beeld tot je hem opent met je sneltoets of vanuit het systeemvak.", "Off: Nook stays out of sight until you open him with your shortcut or from the tray.")}</small></span>
      <input type="checkbox" role="switch" checked={s.showBar !== false} onchange={(e) => nook.saveSettings({ showBar: e.currentTarget.checked })} />
    </label>
    <label class="row">
      <span>{tr("Plek", "Position")}</span>
      <select value={s.placement} onchange={(e) => nook.saveSettings({ placement: e.currentTarget.value as "top" | "floating" })}>
        <option value="top">{tr("Bovenaan het scherm", "At the top of the screen")}</option>
        <option value="floating">{tr("Zwevend op het scherm", "Floating on the screen")}</option>
      </select>
    </label>
    <label class="row">
      <span>{tr("Scherm", "Screen")}</span>
      <select value={s.screenChoice || "auto"} onchange={(e) => nook.saveSettings({ screenChoice: e.currentTarget.value })}>
        <option value="auto">{tr("Automatisch", "Automatic")}</option>
        <option value="main">{tr("Hoofdscherm", "Main display")}</option>
        <option value="mouse">{tr("Volgt je muis", "Follows mouse")}</option>
        {#each screens as name (name)}<option value={name}>{name}</option>{/each}
        {#if s.screenChoice && !["auto", "main", "mouse"].includes(s.screenChoice) && !screens.includes(s.screenChoice)}<option value={s.screenChoice}>{s.screenChoice}</option>{/if}
      </select>
    </label>
    <label class="row"><span>{tr("Verberg Nook als er niets is", "Hide Nook when idle")}</span><input type="checkbox" role="switch" checked={s.hideWhenIdle} onchange={(e) => nook.saveSettings({ hideWhenIdle: e.currentTarget.checked })} /></label>
    <label class="row">
      <span>{tr("Open het hoofdvenster als Nook start", "Open the main window when Nook starts")}<br /><small>{tr("Elke keer dat Nook start, ook als je het venster had gesloten. Bij het inloggen opent het op de achtergrond, zonder het toetsenbord over te nemen.", "Every time Nook starts, also when you had closed it. At login it opens in the background, without taking the keyboard.")}</small></span>
      <input type="checkbox" role="switch" checked={s.openWindowAtLaunch !== false} onchange={(e) => nook.saveSettings({ openWindowAtLaunch: e.currentTarget.checked })} />
    </label>
    <label class="row"><span>{tr("Groter paneel", "Larger panel")}</span><input type="checkbox" role="switch" checked={s.panelLarge} onchange={(e) => nook.saveSettings({ panelLarge: e.currentTarget.checked })} /></label>
    <label class="row"><span>{tr("Starten als ik inlog op de computer", "Open at login")}</span><input type="checkbox" role="switch" checked={launchAtLogin} onchange={(e) => setLaunchAtLogin(e.currentTarget.checked)} /></label>
    {#if caps.os === "windows"}
      <div class="row">
        <span>{tr("Snelkoppeling in het Startmenu", "Start menu shortcut")}{#if shortcutNote}<br /><small>{shortcutNote}</small>{/if}</span>
        <button onclick={repairShortcut}>{tr("Herstellen", "Repair")}</button>
      </div>
    {/if}
  </div>
{/if}
<Voice part="quiet" />
