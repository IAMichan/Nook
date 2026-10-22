<script lang="ts">
  import { onMount } from "svelte";
  import Bar from "./views/Bar.svelte";
  import Main from "./views/Main.svelte";
  import Aside from "./views/services/Aside.svelte";
  import RecordingBadge from "./views/services/RecordingBadge.svelte";
  import ScreenPart from "./views/services/ScreenPart.svelte";
  import Ghost from "./views/services/Ghost.svelte";
  import Toast from "./components/Toast.svelte";
  import { nook, accentCss, onAccent } from "./lib/state.svelte";
  import { quiet } from "./lib/quiet.svelte";

  // De balk bovenaan laadt index.html#bar; het hoofdvenster (en Android) de rest.
  const isBar = location.hash === "#bar";

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
  <Bar />
{:else if location.hash === "#aside"}
  <Aside />
{:else if location.hash === "#recbadge"}
  <RecordingBadge />
{:else if location.hash === "#screenpart"}
  <ScreenPart />
{:else if location.hash === "#ghost"}
  <Ghost />
{:else}
  <Main />
{/if}
<!-- Every window shows its own results in the same toast. -->
<Toast />
