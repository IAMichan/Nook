<script lang="ts">
  import { onMount } from "svelte";
  import Main from "./views/Main.svelte";
  import LazyView from "./components/LazyView.svelte";
  import { retryableView } from "./lib/shell-routes";
  import Toast from "./components/Toast.svelte";
  import { nook, accentCss, onAccent } from "./lib/state.svelte";
  import { quiet } from "./lib/quiet.svelte";

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

  $effect(() => {
    const hex = nook.settings?.accentHex;
    if (hex === undefined) return;
    document.documentElement.style.setProperty("--iris", accentCss(hex));
    document.documentElement.style.setProperty("--on-iris", onAccent(hex));
  });
</script>

{#if isBar}
  <LazyView load={windows["#bar"]} label="Nook bar" />
{:else if location.hash === "#aside"}
  <LazyView load={windows["#aside"]} label="Suggestions" />
{:else if location.hash === "#recbadge"}
  <LazyView load={windows["#recbadge"]} label="Recording" />
{:else if location.hash === "#screenpart"}
  <LazyView load={windows["#screenpart"]} label="Screen selection" />
{:else if location.hash === "#ghost"}
  <LazyView load={windows["#ghost"]} label="Autocomplete" />
{:else}
  <Main />
{/if}
<!-- Every window shows its own results in the same toast. -->
<Toast />
