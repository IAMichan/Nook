<script lang="ts">
  // Settings › About Nook (`aboutSection` on the Mac): the version, the source, what's new, reporting a problem, and
  // the legal notices. Every link opens in the browser.
  import { openUrl } from "@tauri-apps/plugin-opener";
  import { nook } from "../../lib/state.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import { LINKS } from "../../lib/maintenance";

  const app = $derived([
    { title: tr("Broncode", "Source code"), url: LINKS.source },
    { title: tr("Wat is er nieuw", "What's new"), url: LINKS.changes },
    { title: tr("Meld een probleem", "Report a problem"), url: LINKS.report },
  ]);
</script>

<h2>{tr("Over Nook", "About Nook")}</h2>
<p>{tr("Nook {version} voor {os}.", "Nook {version} for {os}.", { version: nook.info?.version ?? "", os: nook.info?.capabilities.os ?? "" })}</p>
<p class="muted">{tr("Nook is je maatje: de ene rustige plek voor alles wat je aandacht vraagt (mensen, coding agents, muziek, je agenda en meer), zodat jij het overzicht houdt en stuurt in plaats van achter dingen aan te jagen.", "Nook is your buddy: the one calm place for everything that needs your attention (people, coding agents, music, your calendar and more), so you keep the overview and steer instead of chase.")}</p>
<h3>{tr("App", "App")}</h3>
<div class="group">
  <div class="row"><span>{tr("Versie", "Version")}</span><code>{nook.info?.version ?? "–"}</code></div>
  {#each app as link (link.url)}
    <div class="row"><span>{link.title}</span><button title={link.url} onclick={() => openUrl(link.url)}>{tr("Openen", "Open")}</button></div>
  {/each}
</div>
<h3>{tr("Juridisch", "Legal")}</h3>
<div class="group">
  <div class="row"><span>{tr("Licentie", "License")}</span><button class="ghost" title={LINKS.license} onclick={() => openUrl(LINKS.license)}>MIT</button></div>
  <div class="row"><span>{tr("Opensourcevermeldingen", "Open source notices")}</span><button title={LINKS.notices} onclick={() => openUrl(LINKS.notices)}>{tr("Openen", "Open")}</button></div>
</div>

<style>
  code { font: var(--text-code); color: var(--text2); user-select: text; }
</style>
