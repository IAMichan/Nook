<script lang="ts">
  import { nook } from "../../lib/state.svelte";
</script>

<h2>Over Nook</h2>
<p>Nook {nook.info?.version} voor {nook.info?.capabilities.os}.</p>
<p class="muted">Vroege versie. Dezelfde Nook als op de Mac, gebouwd met Tauri: de kern in Rust, de interface in Svelte.</p>
      
