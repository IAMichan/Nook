<script lang="ts">
  // Settings › Appearance (`SettingsView+Appearance` on the Mac): Nook first, a live Nook with a mood to preview and its
  // color; then the windows: System, Light or Dark with the theme for each (built-in or an imported VS Code theme),
  // text and layout and the custom colors each folded into one row, and sharing the whole look as one file. The bar
  // stays dark in every look, as the notch on the Mac does. (The Mac's face styles, face and finish, and Nook as a buddy
  // wait for a face Windows can change.)
  import { open as openDialog, save as saveDialog } from "@tauri-apps/plugin-dialog";
  import { invoke } from "@tauri-apps/api/core";
  import Segmented from "./Segmented.svelte";
  import Orb, { type Mood } from "../../components/Orb.svelte";
  import Fold from "./Fold.svelte";
  import InfoLabel from "./InfoLabel.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import ConfirmedButton from "../../components/ui/ConfirmedButton.svelte";
  import { tip } from "../../components/ui/tip";
  import { nook, accentCss } from "../../lib/state.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import { toast } from "../../lib/toast.svelte";
  import { ACCENTS, DENSITIES, THEMES, themeAccent, resolveTheme, type Density, type ThemeSetting } from "../../lib/theme";
  import {
    NOOK_DARK, NOOK_LIGHT, allThemes, cssHex, importVSCodeTheme, lookFile, parseColor, readLook, themePalette, type ColorTheme, type Palette,
  } from "../../lib/palette";
  import { LOOK_PRESETS, type NookLook } from "../../lib/types";
  import { COLOR_GROUPS, COLOR_TOKENS, groupTitle, type ColorGroup } from "../../lib/color-tokens";

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
  // The moods the preview can show (`previewMoods`), as far as Windows' Nook draws them.
  const moods = $derived<{ mood: Mood; title: string }[]>([
    { mood: "idle", title: tr("Rust", "Resting") }, { mood: "working", title: tr("Denkt na", "Thinking") },
    { mood: "waiting", title: tr("Wacht", "Waiting") }, { mood: "done", title: tr("Klaar", "Done") }, { mood: "error", title: tr("Bezorgd", "Worried") },
  ]);
  let mood = $state<Mood>("idle");

  // MARK: Nook's face

  const look_ = $derived<NookLook>(s.nookLook ?? LOOK_PRESETS[1].look);
  const sameLook = (a: NookLook, b: NookLook) => a.eyes === b.eyes && a.mouth === b.mouth && a.gloss === b.gloss && a.glow === b.glow && a.cheeks === b.cheeks;
  const setLook = (patch: Partial<NookLook>) => nook.saveSettings({ nookLook: { ...look_, ...patch } });
  const presetTitle = (id: string) => (id === "minimal" ? tr("Minimaal", "Minimal") : id === "playful" ? tr("Speels", "Playful") : tr("Klassiek", "Classic"));
  const presetDetail = (id: string) => (id === "minimal" ? tr("Stipjes, geen mond, geen glans", "Dots, no mouth, no shine")
    : id === "playful" ? tr("Ronde ogen en een mond die meepraat", "Round eyes and a mouth that talks along") : tr("De Nook die je kent", "The Nook you know"));

  // MARK: Themes

  const themes = $derived(allThemes(s.customThemes));
  const themeTitle = (t: ColorTheme) => {
    switch (t.id) {
      case "nook": return "Nook";
      case "warm": return tr("Warm", "Warm");
      case "mono": return tr("Mono", "Mono");
      case "midnight": return tr("Middernacht", "Midnight");
      case "paper": return tr("Papier", "Paper");
      case "contrast": return tr("Hoog contrast", "High contrast");
      default: return t.name;
    }
  };

  async function importTheme() {
    const picked = await openDialog({ multiple: false, filters: [{ name: "VS Code", extensions: ["json", "jsonc"] }] }).catch(() => null);
    if (typeof picked !== "string") return;
    try {
      const source = await readText(picked);
      const fallback = picked.split(/[\\/]/).pop()?.replace(/\.jsonc?$/i, "") ?? "Theme";
      const result = importVSCodeTheme(source, fallback);
      if (typeof result === "string") throw new Error(result);
      const theme: ColorTheme = { id: `custom-${Date.now().toString(36)}`, name: result.name, source, [result.dark ? "dark" : "light"]: result.palette };
      // It is used at once for the appearance it is made for.
      await nook.saveSettings({
        customThemes: [...(s.customThemes ?? []), theme],
        ...(result.dark ? { darkTheme: theme.id } : { lightTheme: theme.id }),
      });
    } catch {
      toast.error(tr("Dat bestand is geen VS Code-kleurthema.", "That file is not a VS Code color theme."));
    }
  }

  function removeTheme(id: string) {
    nook.saveSettings({
      customThemes: (s.customThemes ?? []).filter((t) => (t as ColorTheme).id !== id),
      ...(s.darkTheme === id ? { darkTheme: "nook" } : {}),
      ...(s.lightTheme === id ? { lightTheme: "nook" } : {}),
    });
  }

  /** A file's text, read by the window from the path the open dialog gave. */
  async function readText(path: string): Promise<string> {
    return invoke<string>("look_read", { path });
  }

  // MARK: Custom colors

  // The appearance being edited; until one is picked, the one Nook shows now.
  let editDark = $state<boolean | null>(null);
  const dark = $derived(editDark ?? look === "dark");
  let group = $state<ColorGroup>("surfaces");
  const overrides = $derived<Record<string, string>>((dark ? s.colorOverrides?.dark : s.colorOverrides?.light) ?? {});
  const changedTotal = $derived(Object.keys(s.colorOverrides?.dark ?? {}).length + Object.keys(s.colorOverrides?.light ?? {}).length);
  const basePalette = $derived<Palette>(themePalette(themes, dark ? s.darkTheme : s.lightTheme, dark));
  // A token's color in the edited appearance: what you set, else the theme's own, else what app.css draws.
  function valueOf(id: string, cssVar: string): string {
    if (overrides[id]) return overrides[id];
    if (id in basePalette) return cssHex(basePalette[id as keyof Palette]);
    if (dark === (look === "dark")) {
      const v = getComputedStyle(document.documentElement).getPropertyValue(cssVar).trim();
      if (parseColor(v) !== null) return v.toLowerCase();
    }
    return cssHex(dark ? NOOK_DARK.paper : NOOK_LIGHT.paper);
  }
  function setColor(id: string, value: string | null) {
    const all = { dark: { ...(s.colorOverrides?.dark ?? {}) }, light: { ...(s.colorOverrides?.light ?? {}) } };
    const side = dark ? all.dark : all.light;
    const themeValue = id in basePalette ? cssHex(basePalette[id as keyof Palette]) : null;
    if (value === null || value.toLowerCase() === themeValue) delete side[id];
    else side[id] = value.toLowerCase();
    nook.saveSettings({ colorOverrides: all });
  }
  function resetAll() {
    const all = { dark: { ...(s.colorOverrides?.dark ?? {}) }, light: { ...(s.colorOverrides?.light ?? {}) } };
    if (dark) all.dark = {}; else all.light = {};
    nook.saveSettings({ colorOverrides: all });
  }

  // MARK: Sharing the look

  async function exportLook() {
    const path = await saveDialog({ defaultPath: `${tr("Mijn Nook-look", "My Nook look")}.nooklook`, filters: [{ name: "Nook look", extensions: ["nooklook"] }] }).catch(() => null);
    if (!path) return;
    const file = lookFile({
      accentHex: s.accentHex, theme: s.theme, darkTheme: s.darkTheme ?? "nook", lightTheme: s.lightTheme ?? "nook",
      customThemes: (s.customThemes ?? []) as ColorTheme[], colorOverrides: { dark: s.colorOverrides?.dark ?? {}, light: s.colorOverrides?.light ?? {} },
      diffColors: s.diffColors ?? "redGreen", density: s.density, nookLook: { ...look_ },
    });
    try {
      await invoke("look_export", { path: path.toLowerCase().endsWith(".nooklook") ? path : `${path}.nooklook`, contents: JSON.stringify(file, null, 2) });
      toast.success(tr("Look geëxporteerd", "Look exported"), path.split(/[\\/]/).pop());
    } catch (e) {
      toast.error(tr("De look kon niet worden bewaard.", "Could not save the look."), e);
    }
  }

  async function importLook() {
    const picked = await openDialog({ multiple: false, filters: [{ name: "Nook look", extensions: ["nooklook"] }] }).catch(() => null);
    if (typeof picked !== "string") return;
    const look = readLook(await readText(picked).catch(() => ""), (s.customThemes ?? []) as ColorTheme[], { darkTheme: s.darkTheme ?? "nook", lightTheme: s.lightTheme ?? "nook" });
    if (!look) {
      toast.error(tr("Dat bestand is geen Nook-look.", "That file is not a Nook look."));
      return;
    }
    const face = look.nookLook ? { ...look_, ...(look.nookLook as Partial<NookLook>) } : undefined;
    await nook.saveSettings({
      ...(look.accentHex !== undefined ? { accentHex: look.accentHex } : {}),
      ...(look.theme ? { theme: look.theme as typeof s.theme } : {}),
      ...(look.density ? { density: look.density as typeof s.density } : {}),
      ...(look.diffColors ? { diffColors: look.diffColors as typeof s.diffColors } : {}),
      darkTheme: look.darkTheme, lightTheme: look.lightTheme, customThemes: look.customThemes ?? [],
      colorOverrides: look.colorOverrides ?? { dark: {}, light: {} },
      ...(face ? { nookLook: face } : {}),
    });
    toast.success(tr("Look geïmporteerd", "Look imported"));
  }
</script>

<div class="preview" role="group" aria-label={tr("Voorbeeld van Nook", "Preview of Nook")}>
  <div class="stage"><Orb size={88} {mood} /></div>
  <select class="mood" bind:value={mood} aria-label={tr("Stemming", "Mood")}>
    {#each moods as m (m.mood)}<option value={m.mood}>{m.title}</option>{/each}
  </select>
</div>

<h3>{tr("Stijl", "Style")}</h3>
<div class="group">
  <div class="presets">
    {#each LOOK_PRESETS as preset (preset.id)}
      {@const chosen = sameLook(preset.look, look_)}
      <button class="preset" class:chosen aria-pressed={chosen} onclick={() => nook.saveSettings({ nookLook: { ...preset.look } })}>
        <Orb size={42} look={preset.look} />
        <span class="preset-name">{presetTitle(preset.id)}</span>
        <span class="preset-detail">{presetDetail(preset.id)}</span>
      </button>
    {/each}
  </div>
  <div class="row">
    <span>{tr("Kleur", "Color")}</span>
    <div class="swatches">
      {#each ACCENTS as a (a)}
        <button class="swatch" class:on={s.accentHex === a} style="--swatch:{accentCss(themeAccent(a, look))}" aria-label={tr("Kleur", "Color")} aria-pressed={s.accentHex === a} onclick={() => nook.saveSettings({ accentHex: a })}></button>
      {/each}
      <label class="picker" use:tip={tr("Eigen kleur", "Your own color")}>
        <input type="color" value={cssHex(s.accentHex)} onchange={(e) => { const v = parseColor(e.currentTarget.value); if (v !== null) nook.saveSettings({ accentHex: v }); }} />
      </label>
    </div>
  </div>
</div>
{#if !LOOK_PRESETS.some((p) => sameLook(p.look, look_))}<p class="note">{tr("Je eigen mix: pas hieronder alles aan, of kies een stijl om opnieuw te beginnen.", "Your own mix: change anything below, or pick a style to start again.")}</p>{/if}

<Fold title={tr("Gezicht en afwerking", "Face and finish")} summary={tr("Ogen, mond, glans, gloed en wangen", "Eyes, mouth, gloss, glow and cheeks")}>
  <div class="row">
    <span>{tr("Ogen", "Eyes")}</span>
    <Segmented label={tr("Ogen", "Eyes")} value={look_.eyes} onchange={(v) => setLook({ eyes: v as NookLook["eyes"] })}
      options={[{ value: "round", label: tr("Rond", "Round") }, { value: "bars", label: tr("Balkjes", "Bars") }, { value: "dots", label: tr("Stipjes", "Dots") }]} />
  </div>
  <div class="row">
    <span>{tr("Mond", "Mouth")}</span>
    <Segmented label={tr("Mond", "Mouth")} value={look_.mouth} onchange={(v) => setLook({ mouth: v as NookLook["mouth"] })}
      options={[{ value: "expressive", label: tr("Expressief", "Expressive") }, { value: "line", label: tr("Lijntje", "Line") }, { value: "none", label: tr("Geen", "None") }]} />
  </div>
  <label class="row"><span>{tr("Glans", "Gloss")}</span><input type="checkbox" role="switch" checked={look_.gloss} onchange={(e) => setLook({ gloss: e.currentTarget.checked })} /></label>
  <label class="row"><span>{tr("Gloed", "Glow")}</span><input type="checkbox" role="switch" checked={look_.glow} onchange={(e) => setLook({ glow: e.currentTarget.checked })} /></label>
  <label class="row"><span>{tr("Blosjes", "Blush")}</span><input type="checkbox" role="switch" checked={look_.cheeks} onchange={(e) => setLook({ cheeks: e.currentTarget.checked })} /></label>
</Fold>

<h3>{tr("Nook als maatje", "Nook as a buddy")}</h3>
<div class="group">
  <label class="row">
    <span>{tr("Kleine momenten", "Little moments")}<br /><small>{tr("Hij springt even als je langskomt, wordt wakker als je terug bent, giechelt na drie tikjes en bloost als je hem aait.", "He hops to say hello, wakes up when you come back, giggles after three pokes and blushes when petted.")}</small></span>
    <input type="checkbox" role="switch" checked={s.buddyMoments !== false} onchange={(e) => nook.saveSettings({ buddyMoments: e.currentTarget.checked })} />
  </label>
</div>

<h3>{tr("Thema", "Theme")}</h3>
<div class="group">
  <div class="row">
    <span>{tr("Weergave", "Appearance")}</span>
    <Segmented label={tr("Weergave", "Appearance")} value={s.theme} options={THEMES.map((t) => ({ value: t, label: themeNames[t] }))} onchange={(t) => nook.saveSettings({ theme: t })} />
  </div>
  <div class="themes">
    {#each themes as t (t.id)}
      <div class="theme">
        <div class="theme-head">
          <span class="theme-name">{themeTitle(t)}</span>
          {#if t.custom}
            <ConfirmedButton class="icon" question={tr("{name} verwijderen?", "Remove {name}?", { name: t.name })} detail={tr("De kleuren worden verwijderd; waar het thema in gebruik was, komt het thema van Nook terug.", "Its colors are deleted; sides that used it go back to Nook’s theme.")}
              confirmTitle={tr("Thema verwijderen", "Remove theme")} onconfirm={() => removeTheme(t.id)}><Ico name="trash-2" size={12} /></ConfirmedButton>
          {/if}
        </div>
        <div class="previews">
          {#each [{ p: t.dark, isDark: true }, { p: t.light, isDark: false }] as side (side.isDark)}
            {#if side.p}
              {@const p = side.p}
              {@const chosen = side.isDark ? (s.darkTheme ?? "nook") === t.id : (s.lightTheme ?? "nook") === t.id}
              <button class="mini" class:chosen style:background={cssHex(p.canvas)} aria-pressed={chosen}
                aria-label={`${themeTitle(t)}: ${side.isDark ? tr("Gebruiken in donkere weergave", "Use in dark appearance") : tr("Gebruiken in lichte weergave", "Use in light appearance")}`}
                use:tip={side.isDark ? tr("Gebruiken in donkere weergave", "Use in dark appearance") : tr("Gebruiken in lichte weergave", "Use in light appearance")}
                onclick={() => nook.saveSettings(side.isDark ? { darkTheme: t.id } : { lightTheme: t.id })}>
                <span class="side" style:background={cssHex(p.surface)}></span>
                <span class="lines">
                  <span class="bar long" style:background={cssHex(p.paper)}></span>
                  <span class="bar short" style:background={cssHex(p.textSecondary)}></span>
                  <span class="dots">
                    <span class="dot" style:background={cssHex(p.accent)}></span><span class="dot" style:background={cssHex(p.mint)}></span><span class="dot" style:background={cssHex(p.coral)}></span>
                  </span>
                </span>
              </button>
            {/if}
          {/each}
        </div>
      </div>
    {/each}
  </div>
  <div class="row"><button onclick={importTheme}>{tr("VS Code-thema importeren…", "Import VS Code theme…")}</button></div>
</div>
<p class="note">{tr("Klik op de donkere of lichte voorvertoning van een thema om het in die weergave te gebruiken. De balk blijft in elk thema donker, net als de notch van een Mac.", "Click a theme's dark or light preview to use it in that appearance. The bar stays dark in every theme, as the notch of a Mac does.")}</p>

<Fold title={tr("Tekst en indeling", "Text and layout")} summary={tr("Dichtheid, diffkleuren, wiskunde en Markdown", "Density, diff colors, math and Markdown")}>
  <div class="row">
    <span>{tr("Dichtheid", "Density")}</span>
    <Segmented label={tr("Dichtheid", "Density")} value={s.density} options={DENSITIES.map((d) => ({ value: d, label: densityNames[d] }))} onchange={(d) => nook.saveSettings({ density: d as Density })} />
  </div>
  <p class="note">{tr("Hoeveel ruimte tekst en rijen krijgen. Compact past meer op het scherm; ruim leest rustiger.", "How much room text and rows get. Compact fits more on screen; spacious reads easier.")}</p>
  <div class="row">
    <span>{tr("Diffkleuren", "Diff colors")}</span>
    <Segmented label={tr("Diffkleuren", "Diff colors")} value={s.diffColors ?? "redGreen"} onchange={(v) => nook.saveSettings({ diffColors: v as "redGreen" | "blueOrange" })}
      options={[{ value: "redGreen", label: tr("Groen & rood", "Green & red") }, { value: "blueOrange", label: tr("Blauw & oranje", "Blue & orange") }]} />
  </div>
  <p class="note">{tr("De kleuren van toegevoegde en verwijderde regels in diffs en wijzigingstellers. Blauw en oranje blijven uit elkaar bij rood-groen kleurenblindheid.", "The colors of added and removed lines in diffs and change counts. Blue and orange stay apart for red-green color blindness.")}</p>
  <label class="row"><span>{tr("Wiskunde weergeven", "Render math")}</span><input type="checkbox" role="switch" checked={s.renderMath !== false} onchange={(e) => nook.saveSettings({ renderMath: e.currentTarget.checked })} /></label>
  <p class="note">{tr("Zet $…$, $$…$$ en wiskundeblokken in antwoorden en Markdown-voorvertoningen op, zonder netwerkverbinding.", "Typesets $…$, $$…$$ and math blocks in answers and Markdown previews, without a network connection.")}</p>
  <label class="row"><span>{tr("Markdown opmaken tijdens het typen", "Style Markdown as you type")}</span><input type="checkbox" role="switch" checked={s.richComposer !== false} onchange={(e) => nook.saveSettings({ richComposer: e.currentTarget.checked })} /></label>
  <p class="note">{tr("Vet, cursief, code, koppen en lijsten tonen hun opmaak in het invoerveld. Wat je verstuurt blijft gewone Markdown.", "Bold, italic, code, headings and lists show their style in the composer. What you send stays plain Markdown.")}</p>
</Fold>

<Fold title={tr("Eigen kleuren", "Custom colors")} summary={changedTotal > 0 ? tr("{n} aangepast", "{n} changed", { n: changedTotal }) : tr("Pas elke kleur van het thema aan", "Change any color of the theme")}>
  <p class="note">{tr("Alle kleuren waarmee Nook tekent. Een kleur die je hier instelt, verandert meteen overal waar hij gebruikt wordt, over het gekozen thema; de ⓘ naast een kleur zegt waar hij te zien is. Herstellen brengt de kleur van het thema terug.", "Every color Nook draws with. A color set here changes every place that uses it at once, over the chosen theme; the ⓘ next to a color says where it shows. Reset brings the theme's own color back.")}</p>
  <div class="row">
    <span>{tr("Kleuren voor", "Colors for")}</span>
    <Segmented label={tr("Kleuren voor", "Colors for")} value={dark ? "dark" : "light"} onchange={(v) => (editDark = v === "dark")}
      options={[{ value: "dark", label: tr("Donker", "Dark") }, { value: "light", label: tr("Licht", "Light") }]} />
  </div>
  {#if dark !== (look === "dark")}
    <p class="note">{dark ? tr("Nook toont nu de lichte kleuren. Wat je hier instelt zie je zodra Nook donker is.", "Nook shows its light colors now. What you set here shows once Nook is dark.") : tr("Nook toont nu de donkere kleuren. Wat je hier instelt zie je zodra Nook licht is.", "Nook shows its dark colors now. What you set here shows once Nook is light.")}</p>
  {/if}
  {#if Object.keys(overrides).length}
    <div class="row">
      <span class="count">{tr("{n} aangepast", "{n} changed", { n: Object.keys(overrides).length })}</span>
      <ConfirmedButton class="" question={tr("Alle kleuren herstellen?", "Reset all colors?")} detail={tr("Elke kleur die je hebt aangepast, gaat terug naar die van het thema.", "Every color you changed goes back to the theme’s own.")}
        confirmTitle={tr("Alles herstellen", "Reset all")} onconfirm={resetAll} />
    </div>
  {/if}
  <label class="row">
    <span>{tr("Groep", "Group")}</span>
    <select bind:value={group}>
      {#each COLOR_GROUPS as g (g)}
        {@const changed = COLOR_TOKENS.filter((t) => t.group === g && overrides[t.id]).length}
        <option value={g}>{changed ? `${groupTitle(g)} · ${tr("{n} aangepast", "{n} changed", { n: changed })}` : groupTitle(g)}</option>
      {/each}
    </select>
  </label>
  {#each COLOR_TOKENS.filter((t) => t.group === group) as token (token.id)}
    {@const value = valueOf(token.id, token.cssVar)}
    <div class="row token">
      <InfoLabel label={token.title()} info={token.info()} />
      <span class="token-value">
        {#if overrides[token.id]}
          <button class="icon" use:tip={tr("Terug naar de kleur van het thema", "Reset to the theme's color")} onclick={() => setColor(token.id, null)}><Ico name="rotate-ccw" size={12} /></button>
        {/if}
        <code class:changed={!!overrides[token.id]}>{value}</code>
        <input type="color" {value} aria-label={token.title()} onchange={(e) => setColor(token.id, e.currentTarget.value)} />
      </span>
    </div>
  {/each}
</Fold>

<h3>{tr("Je look delen", "Share your look")}</h3>
<div class="group">
  <div class="row">
    <span class="inline-buttons"><button onclick={exportLook}>{tr("Look exporteren…", "Export look…")}</button><button onclick={importLook}>{tr("Look importeren…", "Import look…")}</button></span>
  </div>
</div>
<p class="note">{tr("Bewaart je accentkleur, weergave, thema's, eigen kleuren, diffkleuren, dichtheid en het gezicht van Nook als één bestand. Wie het importeert krijgt dezelfde look; verder verandert er niets.", "Saves your accent, appearance, themes, custom colors, diff colors, density and Nook's face as one file. Whoever imports it gets the same look; nothing else of theirs changes.")}</p>

<style>
  /* The live preview (`lookPreview`): Nook at 88 px in a 150 by 130 stage, the mood menu under it, on the surface. */
  .preview { display: flex; flex-direction: column; align-items: center; gap: var(--space-8); padding: var(--space-16) var(--space-12); background: var(--surface); border-radius: var(--radius-sheet); }
  .stage { display: grid; place-items: center; width: 150px; height: 130px; }
  .mood { background-color: var(--settings-fill) !important; color: var(--paper) !important; border-radius: var(--radius-control) !important; }
  /* The three styles (`lookPresetCard`): a card each with Nook in that look, its name and one line; the chosen one
     outlined in paper. */
  .presets { display: grid; grid-template-columns: repeat(3, 1fr); gap: var(--space-8); padding: var(--space-12) 0; border-bottom: 1px solid var(--separator); }
  .preset { display: flex; flex-direction: column; align-items: center; gap: var(--space-8); padding: var(--space-16) var(--space-8) var(--space-24); background: var(--graphite); border: 1px solid transparent; border-radius: var(--radius-card); text-align: center; }
  .preset.chosen { border-color: var(--paper); background: var(--smoke); }
  .preset:hover:not(:disabled) { background: var(--smoke); }
  .preset-name { font: var(--text-title); color: var(--paper); }
  .preset-detail { font: var(--text-detail); color: var(--text2); }
  /* A swatch (`accentRow`): an 18 px dot with 2 px of room, the chosen one ringed in paper; then your own color. */
  .swatches { display: flex; align-items: center; gap: var(--space-4); }
  .swatch { width: 22px; height: 22px; padding: var(--space-2); border: 1.5px solid transparent; border-radius: 50%; background: var(--swatch) content-box; }
  .swatch.on { border-color: var(--paper); }
  .picker { display: inline-grid; place-items: center; }
  .picker input { width: 40px; height: 22px; padding: 0; overflow: hidden; border: 1px solid var(--line2); border-radius: var(--radius-pill); background: none; cursor: pointer; }
  /* The color well is a capsule filled with the color, as the Mac's `ColorPicker` draws it (WebView2 is Chromium). */
  .picker input::-webkit-color-swatch-wrapper { padding: 0; }
  .picker input::-webkit-color-swatch { border: none; border-radius: var(--radius-pill); }
  .token input[type="color"] { width: 26px; height: 22px; padding: 0; border: 1px solid var(--line2); border-radius: var(--radius-chip); background: none; cursor: pointer; }
  /* The theme grid (`themeCard`): a graphite card per theme, its name, and a small window per appearance it has. */
  .themes { display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); gap: var(--space-8); padding: var(--space-12) 0; border-bottom: 1px solid var(--separator); }
  .theme { display: flex; flex-direction: column; gap: var(--space-6); padding: var(--space-8); background: var(--graphite); border-radius: var(--radius-panel); }
  .theme-head { display: flex; align-items: center; justify-content: space-between; min-height: 18px; }
  .theme-name { font: var(--text-emphasis); color: var(--paper); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .previews { display: flex; gap: var(--space-6); }
  .mini { flex: 1; display: flex; height: 44px; padding: 0; overflow: hidden; border: 1px solid var(--line2); border-radius: var(--radius-chip); cursor: pointer; }
  .mini.chosen { border: 2px solid var(--iris); }
  .mini:hover:not(:disabled) { filter: brightness(1.05); }
  .side { width: 16px; flex: none; }
  .lines { flex: 1; display: flex; flex-direction: column; gap: 3px; padding: 5px; }
  .bar { height: 3px; border-radius: var(--radius-pill); }
  .bar.long { width: 28px; }
  .bar.short { width: 20px; }
  .dots { margin-top: auto; display: flex; gap: 3px; }
  .dot { width: 6px; height: 6px; border-radius: 50%; }
  .theme :global(.icon), .token :global(.icon) { display: grid; place-items: center; width: 22px; height: 22px; padding: 0; border: none; background: none; color: var(--text3); }
  .theme :global(.icon:hover:not(:disabled)), .token :global(.icon:hover:not(:disabled)) { color: var(--paper); background: none; }
  .token { flex-wrap: nowrap; }
  .token-value { display: inline-flex; align-items: center; gap: var(--space-8); }
  .token code { font: var(--text-code); color: var(--text3); }
  .token code.changed { color: var(--text-strong); }
  .count { color: var(--text2); font: var(--text-detail); }
  .inline-buttons { display: inline-flex; gap: var(--space-8); }
</style>
