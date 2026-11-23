<script lang="ts">
  import { onMount } from "svelte";
  import Main from "./views/Main.svelte";
  import LazyView from "./components/LazyView.svelte";
  import { retryableView } from "./lib/shell-routes";
  import Toast from "./components/Toast.svelte";
  import ConfirmHost from "./components/ui/ConfirmHost.svelte";
  import FilePreview from "./components/FilePreview.svelte";
  import SelectionAsk from "./components/SelectionAsk.svelte";
  import { nook, accentCss, onAccent } from "./lib/state.svelte";
  import { quiet } from "./lib/quiet.svelte";
  import { tr } from "./lib/i18n.svelte";
  import { ACCENTS, isDensity, resolveTheme, themeAccent } from "./lib/theme";
  import { NOOK_DARK, NOOK_LIGHT, allThemes, cssHex, diffColors, paletteVars, themePalette, withOverrides } from "./lib/palette";

  // De balk bovenaan laadt index.html#bar; het hoofdvenster (en Android) de rest.
  const isBar = location.hash === "#bar";
  // Keep auxiliary windows and their route imports out of main-window startup.
  const windows = {
    "#bar": retryableView(() => import("./views/Bar.svelte")),
    "#mirror": retryableView(() => import("./views/BarMirror.svelte")),
    "#aside": retryableView(() => import("./views/services/Aside.svelte")),
    "#recbadge": retryableView(() => import("./views/services/RecordingBadge.svelte")),
    "#screenpart": retryableView(() => import("./views/services/ScreenPart.svelte")),
    "#ghost": retryableView(() => import("./views/services/Ghost.svelte")),
    "#tab": retryableView(() => import("./views/TabWindow.svelte")),
  };

  onMount(() => {
    if (isBar) document.body.classList.add("bar");
    nook.start();
    quiet.start();
  });

  // Settings › Appearance: the main window follows System, Light or Dark; the bar and the other overlays stay dark, as
  // the notch on the Mac does in every theme.
  const followsTheme = location.hash === "" || location.hash === "#main" || location.hash === "#tab";
  let systemDark = $state(typeof matchMedia === "function" ? matchMedia("(prefers-color-scheme: dark)").matches : true);
  $effect(() => {
    if (typeof matchMedia !== "function") return;
    const query = matchMedia("(prefers-color-scheme: dark)");
    const changed = () => (systemDark = query.matches);
    query.addEventListener("change", changed);
    return () => query.removeEventListener("change", changed);
  });
  const look = $derived(followsTheme ? resolveTheme(nook.settings?.theme, systemDark) : "dark");

  $effect(() => {
    const root = document.documentElement;
    root.dataset.theme = look;
    root.style.colorScheme = look;
    const density = nook.settings?.density;
    if (followsTheme && isDensity(density) && density !== "comfortable") root.dataset.density = density;
    else delete root.dataset.density;
  });

  // The chosen theme for this look, the colors set by hand and the diff colors (`lib/palette.ts`), as CSS variables on
  // the main window; Nook's own theme untouched sets none, so app.css stays its source.
  const themeId = $derived(look === "dark" ? nook.settings?.darkTheme : nook.settings?.lightTheme);
  const palette = $derived.by(() => {
    const s = nook.settings;
    const dark = look === "dark";
    const base = themePalette(allThemes(s?.customThemes), followsTheme ? themeId : "nook", dark);
    const p = followsTheme ? withOverrides(base, s?.colorOverrides?.[look]) : base;
    const diff = diffColors(p, followsTheme ? s?.diffColors : "redGreen");
    return { ...p, added: diff.added, removed: diff.removed };
  });
  let themed: string[] = [];
  $effect(() => {
    const root = document.documentElement;
    const base = look === "dark" ? NOOK_DARK : NOOK_LIGHT;
    const vars = paletteVars(palette, base);
    if (palette.canvas !== base.canvas) vars["--sidebar"] = cssHex(look === "dark" ? palette.canvas : palette.well);
    delete vars["--iris"];
    for (const name of themed) if (!(name in vars)) root.style.removeProperty(name);
    for (const [name, value] of Object.entries(vars)) root.style.setProperty(name, value);
    themed = Object.keys(vars);
  });

  $effect(() => {
    const chosen = nook.settings?.accentHex;
    if (chosen === undefined) return;
    // Nook's default accent follows the theme (a theme brings its own); a color you picked wins.
    const base = look === "dark" ? NOOK_DARK : NOOK_LIGHT;
    const hex = chosen === ACCENTS[0] && palette.accent !== base.accent ? palette.accent : themeAccent(chosen, look);
    document.documentElement.style.setProperty("--iris", accentCss(hex));
    document.documentElement.style.setProperty("--on-iris", onAccent(hex));
  });
</script>

{#if isBar}
  <LazyView load={windows["#bar"]} label={tr("Nook-balk", "Nook bar")} />
{:else if location.hash === "#mirror"}
  <LazyView load={windows["#mirror"]} label="Nook" />
{:else if location.hash === "#aside"}
  <LazyView load={windows["#aside"]} label={tr("Suggesties", "Suggestions")} />
{:else if location.hash === "#recbadge"}
  <LazyView load={windows["#recbadge"]} label={tr("Opname", "Recording")} />
{:else if location.hash === "#screenpart"}
  <LazyView load={windows["#screenpart"]} label={tr("Schermselectie", "Screen selection")} />
{:else if location.hash === "#ghost"}
  <LazyView load={windows["#ghost"]} label={tr("Aanvullen", "Autocomplete")} />
{:else if location.hash === "#tab"}
  <!-- A tab of the main window in a window of its own (split view's "In its own window"). -->
  <LazyView load={windows["#tab"]} label="Nook" />
{:else}
  <Main />
{/if}
<!-- Words selected in the main window, bar, or detached tab windows: a bar to ask Nook or quote into an agent. -->
<SelectionAsk />
<!-- Every window shows its own results in the same toast, and asks before what cannot be undone in the same dialog. -->
<Toast />
<ConfirmHost />
<FilePreview />
