<script lang="ts">
  // Settings › Appearance (`SettingsView+Appearance` on the Mac): System, Light or Dark for the windows, Nook's color,
  // and how much room text and rows get. The bar stays dark in every look, as the notch on the Mac does.
  import { nook, accentCss } from "../../lib/state.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import { ACCENTS, DENSITIES, THEMES, themeAccent, resolveTheme, type Density, type ThemeSetting } from "../../lib/theme";

  const s = $derived(nook.settings!);
  const themeNames = $derived<Record<ThemeSetting, string>>({
    system: tr("Systeem", "System"), light: tr("Licht", "Light"), dark: tr("Donker", "Dark"),
  });
  const densityNames = $derived<Record<Density, string>>({
    compact: tr("Compact", "Compact"), comfortable: tr("Comfortabel", "Comfortable"), spacious: tr("Ruim", "Spacious"),
  });
  const systemDark = typeof matchMedia === "function" ? matchMedia("(prefers-color-scheme: dark)").matches : true;
  // The swatches show each accent as it is drawn in the look that applies now.
  const look = $derived(resolveTheme(s.theme, systemDark));
</script>

<h2>{tr("Weergave", "Appearance")}</h2>
<h3>{tr("Thema", "Theme")}</h3>
<div class="group">
  <div class="row">
    <span>{tr("Weergave", "Appearance")}</span>
    <div class="segments" role="radiogroup" aria-label={tr("Weergave", "Appearance")}>
      {#each THEMES as t (t)}
        <button role="radio" aria-checked={s.theme === t} class:on={s.theme === t} onclick={() => nook.saveSettings({ theme: t })}>
          <span class="preview {t}" aria-hidden="true"><span></span></span>{themeNames[t]}
        </button>
      {/each}
    </div>
  </div>
  <p class="faint note">{tr("Systeem volgt de lichte of donkere modus van je computer. De balk blijft in elk thema donker, net als de notch van een Mac.", "System follows your computer's light or dark mode. The bar stays dark in every theme, as the notch of a Mac does.")}</p>
  <div class="row">
    <span>{tr("Kleur van Nook", "Nook's color")}</span>
    <div class="swatches">
      {#each ACCENTS as a (a)}
        <button class="swatch" class:on={s.accentHex === a} style="background:{accentCss(themeAccent(a, look))}" aria-label={tr("Kleur", "Color")} aria-pressed={s.accentHex === a} onclick={() => nook.saveSettings({ accentHex: a })}></button>
      {/each}
    </div>
  </div>
  <p class="faint note">{tr("De kleur van de belangrijkste knoppen. In licht wordt Nooks zachte wit bijna zwart, zodat het leesbaar blijft.", "The color of the main buttons. In light, Nook's soft white turns near-black so it stays readable.")}</p>
</div>
<h3>{tr("Tekst en indeling", "Text and layout")}</h3>
<div class="group">
  <label class="row">
    <span>{tr("Dichtheid", "Density")}</span>
    <select value={s.density} onchange={(e) => nook.saveSettings({ density: e.currentTarget.value as Density })}>
      {#each DENSITIES as d (d)}<option value={d}>{densityNames[d]}</option>{/each}
    </select>
  </label>
  <p class="faint note">{tr("Hoeveel ruimte tekst en rijen krijgen. Compact past meer op het scherm; ruim leest rustiger.", "How much room text and rows get. Compact fits more on screen; spacious reads easier.")}</p>
</div>

<style>
  .segments { display: inline-flex; gap: var(--space-8); flex-wrap: wrap; }
  .segments button { display: inline-flex; flex-direction: column; align-items: center; gap: var(--space-6); padding: var(--space-8) var(--space-12); background: transparent; }
  .segments button.on { border-color: var(--iris); background: var(--row-selected); }
  .preview { position: relative; width: 56px; height: 36px; border-radius: var(--radius-chip); border: 1px solid var(--line2); overflow: hidden; }
  .preview span { position: absolute; left: 8px; right: 8px; top: 8px; height: 6px; border-radius: 3px; }
  .preview.dark { background: #000; }
  .preview.dark span { background: #f5f5f5; }
  .preview.light { background: #fcfcfc; }
  .preview.light span { background: #18181b; }
  .preview.system { background: linear-gradient(135deg, #fcfcfc 50%, #000 50%); }
  .preview.system span { background: linear-gradient(90deg, #18181b 50%, #f5f5f5 50%); }
</style>
