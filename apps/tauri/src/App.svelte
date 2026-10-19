<script lang="ts">
  import { onMount } from "svelte";
  import Bar from "./views/Bar.svelte";
  import Main from "./views/Main.svelte";
  import { nook, accentCss, onAccent } from "./lib/state.svelte";

  // De balk bovenaan laadt index.html#bar; het hoofdvenster (en Android) de rest.
  const isBar = location.hash === "#bar";

  onMount(() => {
    if (isBar) document.body.classList.add("bar");
    nook.start();
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
{:else}
  <Main />
{/if}
