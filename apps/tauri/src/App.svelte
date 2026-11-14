<script lang="ts">
  import { onMount } from "svelte";
  import Main from "./views/Main.svelte";
  import LazyView from "./components/LazyView.svelte";
  import { retryableView } from "./lib/shell-routes";
  import Toast from "./components/Toast.svelte";
  import SelectionAsk from "./components/SelectionAsk.svelte";
  import { nook, accentCss, onAccent } from "./lib/state.svelte";
  import { quiet } from "./lib/quiet.svelte";
  import { tr } from "./lib/i18n.svelte";
  import { isDensity, resolveTheme, themeAccent } from "./lib/theme";

  // De balk bovenaan laadt index.html#bar; het hoofdvenster (en Android) de rest.
  const isBar = location.hash === "#bar";
  // Keep auxiliary windows and their route imports out of main-window startup.
  const windows = {
    "#bar": retryableView(() => import("./views/Bar.svelte")),
    "#aside": retryableView(() => import("./views/services/Aside.svelte")),
    "#recbadge": retryableView(() => import("./views/services/RecordingBadge.svelte")),
    "#screenpart": retryableView(() => import("./views/services/ScreenPart.svelte")),
    "#ghost": retryableView(() => import("./views/services/Ghost.svelte")),
  };

  onMount(() => {
    if (isBar) document.body.classList.add("bar");
    nook.start();
    quiet.start();
  });

  // Settings › Appearance: the main window follows System, Light or Dark; the bar and the other overlays stay dark, as
  // the notch on the Mac does in every theme.
  const followsTheme = location.hash === "" || location.hash === "#main";
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

  $effect(() => {
    const chosen = nook.settings?.accentHex;
    if (chosen === undefined) return;
    const hex = themeAccent(chosen, look);
    document.documentElement.style.setProperty("--iris", accentCss(hex));
    document.documentElement.style.setProperty("--on-iris", onAccent(hex));
  });
</script>

{#if isBar}
  <LazyView load={windows["#bar"]} label={tr("Nook-balk", "Nook bar")} />
{:else if location.hash === "#aside"}
  <LazyView load={windows["#aside"]} label={tr("Suggesties", "Suggestions")} />
{:else if location.hash === "#recbadge"}
  <LazyView load={windows["#recbadge"]} label={tr("Opname", "Recording")} />
{:else if location.hash === "#screenpart"}
  <LazyView load={windows["#screenpart"]} label={tr("Schermselectie", "Screen selection")} />
{:else if location.hash === "#ghost"}
  <LazyView load={windows["#ghost"]} label={tr("Aanvullen", "Autocomplete")} />
{:else}
  <Main />
  <!-- Words selected anywhere in the main window: a bar to ask Nook about them. -->
  <SelectionAsk />
{/if}
<!-- Every window shows its own results in the same toast. -->
<Toast />
