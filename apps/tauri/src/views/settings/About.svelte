<script lang="ts">
  import { nook } from "../../lib/state.svelte";
  import { tr } from "../../lib/i18n.svelte";
</script>

<h2>{tr("Over Nook", "About Nook")}</h2>
<p>{tr("Nook {version} voor {os}.", "Nook {version} for {os}.", { version: nook.info?.version ?? "", os: nook.info?.capabilities.os ?? "" })}</p>
<p class="muted">{tr("Vroege versie. Dezelfde Nook als op de Mac, gebouwd met Tauri: de kern in Rust, de interface in Svelte.", "Early version. The same Nook as on the Mac, built with Tauri: the core in Rust, the interface in Svelte.")}</p>
      
