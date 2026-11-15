<script lang="ts">
  // Under the header of every tab (`ConnectionLine`): why the computer cannot be reached, once it has been away a moment.
  import { tr } from "../../../lib/i18n.svelte";
  import { newerMac, versionNotice, type ClientView } from "../../../lib/companion";
  import Ico from "./Ico.svelte";
  import Banner from "./Banner.svelte";
  let { view }: { view: ClientView } = $props();
  let away = $state(false);
  const notice = $derived(view.phase === "connected" ? versionNotice(view) : null);
  $effect(() => {
    if (view.phase !== "offline") return void (away = false);
    const timer = setTimeout(() => (away = true), 800);
    return () => clearTimeout(timer);
  });
</script>

{#if notice === "macTooOld"}
  <Banner icon="circle-arrow-down">{tr("Werk Nook op je Mac bij: die is te oud voor deze versie van de app.", "Update Nook on your Mac: it is too old for this version of the app.")}</Banner>
{:else if notice === "phoneTooOld"}
  <Banner icon="circle-arrow-down">{tr("Werk de app bij: Nook op je Mac heeft een nieuwere app nodig.", "Update the app: Nook on your Mac needs a newer version of the app.")}</Banner>
{:else if notice === "macBehind"}
  <Banner icon="circle-arrow-down">{tr("Nook op je Mac loopt een versie achter op deze app. Werk het bij om alles te gebruiken wat de app biedt.", "Nook on your Mac is a version behind this app. Update it to use everything the app offers.")}</Banner>
{:else if notice === "phoneBehind" || (view.phase === "connected" && newerMac(view))}
  <Banner icon="circle-arrow-down">{tr("Deze app loopt een versie achter op Nook op je Mac. Werk de app bij om alles van Nook te gebruiken.", "This app is a version behind Nook on your Mac. Update it to use everything Nook offers.")}</Banner>
{/if}
{#if away}
  <div class="line">
    <Ico name="wifi-off" size={13} stroke={2.2} />
    <span class="text"><span>{view.reason || tr("Zoeken naar je Mac…", "Looking for your Mac…")}</span></span>
  </div>
{/if}

<style>
  .line { display: flex; align-items: baseline; gap: 6px; padding: 0 4px; font: var(--pt-detail); color: var(--text2); animation: in 250ms ease-out; }
  .line :global(svg) { position: relative; top: 2px; }
  .text { display: flex; flex-direction: column; gap: 2px; }
  @keyframes in { from { opacity: 0; } }
</style>
