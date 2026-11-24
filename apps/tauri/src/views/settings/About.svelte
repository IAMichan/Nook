<script lang="ts">
  import { tip } from "../../components/ui/tip";
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

<h3>{tr("App", "App")}</h3>
<div class="group">
  <div class="row"><span>{tr("Versie", "Version")}</span><code>{nook.info?.version ?? "–"}</code></div>
  {#each app as link (link.url)}
    <div class="row"><span>{link.title}</span><button class="small" use:tip={link.url} onclick={() => openUrl(link.url)}>{tr("Openen", "Open")}</button></div>
  {/each}
</div>
<h3>{tr("Juridisch", "Legal")}</h3>
<div class="group">
  <div class="row"><span>{tr("Licentie", "License")}</span><button class="ghost license-link" use:tip={LINKS.license} onclick={() => openUrl(LINKS.license)}>MIT</button></div>
  <div class="row"><span>{tr("Opensourcevermeldingen", "Open source notices")}</span><button class="small" use:tip={LINKS.notices} onclick={() => openUrl(LINKS.notices)}>{tr("Openen", "Open")}</button></div>
</div>

<style>
  code { font: var(--text-code); color: var(--text2); user-select: text; }
  .license-link { padding: 0; border: none; background: none; color: var(--iris); font: var(--text-body); }
  .license-link:hover { background: none; text-decoration: underline; }
</style>
