<script lang="ts">
  // Geheugen: wat Nook over je weet en of hij zelf leert.
  import { nook } from "../../lib/state.svelte";

  const s = $derived(nook.settings!);
</script>

<h2>Geheugen</h2>
<div class="group">
  <label class="row"><span>Gebruik wat Nook weet bij elke vraag</span><input type="checkbox" checked={s.useMemory} onchange={(e) => nook.saveSettings({ useMemory: e.currentTarget.checked })} /></label>
  <label class="row"><span>Leer zelf van gesprekken</span><input type="checkbox" checked={s.learnFromChats} onchange={(e) => nook.saveSettings({ learnFromChats: e.currentTarget.checked })} /></label>
</div>
      
