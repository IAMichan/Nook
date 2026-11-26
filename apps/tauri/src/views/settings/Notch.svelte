<script lang="ts">
  // General › Bar & windows (the Mac's Notch & windows, `notchSection`): everywhere Nook shows in one group, in the
  // Mac's order (place, screen, hiding when idle), then how it behaves in meetings and while you share your screen.
  // Windows has no notch: the bar's size, starting with the computer and the Start menu shortcut are its own rows.
  import { api } from "../../lib/api";
  import { nook } from "../../lib/state.svelte";
  import { enable, disable, isEnabled } from "@tauri-apps/plugin-autostart";
  import { tr } from "../../lib/i18n.svelte";
  import SettingFieldRow from "./SettingFieldRow.svelte";
  import SettingNote from "./SettingNote.svelte";
  import SettingsSection from "./SettingsSection.svelte";
  import SettingToggle from "./SettingToggle.svelte";
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
  let shortcutStatus = $state<{ tone: "success" | "error"; text: string } | null>(null);
  async function repairShortcut() {
    shortcutStatus = await api.repairStartMenuShortcut().then(
      () => ({ tone: "success" as const, text: tr("Snelkoppeling in het Startmenu gemaakt.", "Start menu shortcut created.") }),
      (e) => ({ tone: "error" as const, text: String(e) }),
    );
  }
</script>

{#if caps?.desktop}
  <SettingsSection title={tr("Waar Nook staat", "Where Nook shows")}>
    <SettingToggle
      title={tr("Nook in de balk", "Nook in the bar")}
      detail={tr("Uit: Nook blijft uit beeld tot je hem opent met je sneltoets of vanuit het systeemvak.", "Off: Nook stays out of sight until you open him with your shortcut or from the tray.")}
      checked={s.showBar !== false}
      onchange={(showBar) => nook.saveSettings({ showBar })}
    />
    <SettingFieldRow title={tr("Plek", "Position")}>
      <select value={s.placement} onchange={(e) => nook.saveSettings({ placement: e.currentTarget.value as "top" | "floating" })}>
        <option value="top">{tr("Bovenaan het scherm", "At the top of the screen")}</option>
        <option value="floating">{tr("Zwevend op het scherm", "Floating on the screen")}</option>
      </select>
    </SettingFieldRow>
    {#if s.placement !== "floating"}
      <SettingToggle
        title={tr("Toon Nook op elk scherm", "Show Nook on every screen")}
        detail={tr("Elk aangesloten scherm krijgt een balk. Nook opent op het scherm waar je muis is.", "Every connected screen gets a bar. Nook opens on the screen your mouse is on.")}
        checked={!!s.barOnAllScreens}
        onchange={(barOnAllScreens) => nook.saveSettings({ barOnAllScreens })}
      />
    {/if}
    <SettingFieldRow title={tr("Scherm", "Screen")}>
      <select disabled={s.placement !== "floating" && !!s.barOnAllScreens} value={s.screenChoice || "auto"} onchange={(e) => nook.saveSettings({ screenChoice: e.currentTarget.value })}>
        <option value="auto">{tr("Automatisch", "Automatic")}</option>
        <option value="main">{tr("Hoofdscherm", "Main display")}</option>
        <option value="mouse">{tr("Volgt je muis", "Follows mouse")}</option>
        {#each screens as name (name)}<option value={name}>{name}</option>{/each}
        {#if s.screenChoice && !["auto", "main", "mouse"].includes(s.screenChoice) && !screens.includes(s.screenChoice)}<option value={s.screenChoice}>{s.screenChoice}</option>{/if}
      </select>
    </SettingFieldRow>
    <SettingToggle
      title={tr("Verberg Nook als er niets is", "Hide Nook when idle")}
      checked={s.hideWhenIdle}
      onchange={(hideWhenIdle) => nook.saveSettings({ hideWhenIdle })}
    />
    <SettingToggle
      title={tr("Open het paneel als ik naar de balk wijs", "Open panel when hovering over the bar")}
      checked={s.openOnHover !== false}
      onchange={(openOnHover) => nook.saveSettings({ openOnHover })}
    />
    <SettingToggle
      title={tr("Open het hoofdvenster als Nook start", "Open the main window when Nook starts")}
      detail={tr("Elke keer dat Nook start, ook als je het venster had gesloten. Bij het inloggen opent het op de achtergrond, zonder het toetsenbord over te nemen.", "Every time Nook starts, also when you had closed it. At login it opens in the background, without taking the keyboard.")}
      checked={s.openWindowAtLaunch !== false}
      onchange={(openWindowAtLaunch) => nook.saveSettings({ openWindowAtLaunch })}
    />
    <SettingToggle
      title={tr("Groter paneel", "Larger panel")}
      checked={s.panelLarge}
      onchange={(panelLarge) => nook.saveSettings({ panelLarge })}
    />
    <SettingToggle
      title={tr("Starten als ik inlog op de computer", "Open at login")}
      checked={launchAtLogin}
      onchange={setLaunchAtLogin}
    />
    {#if caps.os === "windows"}
      <SettingFieldRow title={tr("Snelkoppeling in het Startmenu", "Start menu shortcut")}>
        <button type="button" onclick={repairShortcut}>{tr("Herstellen", "Repair")}</button>
      </SettingFieldRow>
      {#if shortcutStatus}
        <SettingNote tone={shortcutStatus.tone} text={shortcutStatus.text} />
      {/if}
    {/if}
  </SettingsSection>
{/if}
<Voice part="quiet" />
