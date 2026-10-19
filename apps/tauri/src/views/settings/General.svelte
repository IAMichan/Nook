<script lang="ts">
  // Algemeen: taal, plek van de balk, kleur, sneltoetsen.
  import { nook, accentCss } from "../../lib/state.svelte";

  const s = $derived(nook.settings!);
  const accents = [0xf4f3f7, 0x8b7bff, 0x46e0a6, 0xffb84d, 0xff8a5b, 0x5ab8ff, 0xff6bb5];
  const shortcutNames: Record<string, string> = {
    chat: "Chatten", talk: "Praten", window: "Hoofdvenster", lookAlong: "Meekijken",
  };
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
      
