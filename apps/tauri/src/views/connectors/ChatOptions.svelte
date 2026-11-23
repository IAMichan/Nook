<script lang="ts">
  // The chat options at the end of Settings › Accounts & connections › Chats (`ChatOptionsSection` on the Mac): how
  // reading works when you open a chat, and the GIF key. The chat apps themselves are linked above, like everything else.
  // Collecting chats from other apps' notifications follows with CH-04 (Windows' notification reader).
  import { invoke } from "@tauri-apps/api/core";
  import { openUrl } from "@tauri-apps/plugin-opener";
  import { chatOptions } from "../../lib/chat-options.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import { toast } from "../../lib/toast.svelte";
  import ConfirmedButton from "../../components/ui/ConfirmedButton.svelte";
  import Fold from "../settings/Fold.svelte";

  let giphyKey = $state("");
  let giphySet = $state(false);
  $effect(() => {
    invoke<boolean>("chat_giphy_key_set").then((on) => (giphySet = on)).catch(() => {});
  });

  async function saveKey() {
    const key = giphyKey.trim();
    if (!key) return;
    try {
      await invoke("chat_giphy_key_save", { key });
      giphyKey = "";
      giphySet = true;
      toast.success(tr("GIPHY-sleutel bewaard", "GIPHY key saved"));
    } catch {
      toast.error(tr("De GIPHY-sleutel kon niet bewaard worden", "The GIPHY key could not be saved"));
    }
  }

  async function removeKey() {
    await invoke("chat_giphy_key_remove").catch(() => {});
    giphySet = false;
  }
</script>

<h3>{tr("Lezen", "Reading")}</h3>
<div class="group">
  <label class="row">
    <span>{tr("Gelezen in Nook bij openen", "Read in Nook when opened")}<br /><span class="faint small">{tr("Een chat die je opent, is gelezen in Nook, ook na een herstart.", "A chat you open is read in Nook, also after a restart.")}</span></span>
    <input type="checkbox" role="switch" checked={chatOptions.readOnOpen} onchange={(e) => chatOptions.setReadOnOpen(e.currentTarget.checked)} />
  </label>
  {#if chatOptions.readOnOpen}
    <label class="row">
      <span>{tr("Ook gelezen in de app", "Also read in the app")}<br /><span class="faint small">{tr("Nook laat de app van de chat weten dat je hem opende (waar Nook dat kan): de chat is dan ook op je telefoon gelezen en wie schreef, ziet het.", "Nook tells the chat's app you opened it (where Nook can): the chat is then read on your phone too, and whoever wrote sees it.")}</span></span>
      <input type="checkbox" role="switch" checked={chatOptions.readInAppOnOpen} onchange={(e) => chatOptions.setReadInAppOnOpen(e.currentTarget.checked)} />
    </label>
  {/if}
</div>

<!-- GIFs work with Nook's own key; a key of your own is only for whoever runs into its limit, folded away. -->
<Fold title={tr("GIF's", "GIFs")} summary={tr("Optioneel: een eigen GIPHY-sleutel", "Optional: a GIPHY key of your own")} keys={[tr("GIF's", "GIFs")]}>
  <div class="row column">
    <span>{tr("GIPHY API-sleutel", "GIPHY API key")}<br /><span class="faint small">{tr("Niet nodig: Nook heeft een gedeelde sleutel. Raakt die op, plak dan je eigen (gratis op developers.giphy.com).", "Not needed: Nook has a shared key. If it runs out, paste your own (free at developers.giphy.com).")}</span></span>
    <span class="inline key">
      <input type="password" bind:value={giphyKey} placeholder={giphySet ? "••••••••" : tr("GIPHY API-sleutel", "GIPHY API key")} aria-label={tr("GIPHY API-sleutel", "GIPHY API key")} onkeydown={(e) => e.key === "Enter" && saveKey()} />
      <button onclick={saveKey} disabled={!giphyKey.trim()}>{tr("Bewaar", "Save")}</button>
      {#if giphySet}
        <ConfirmedButton confirmTitle={tr("Verwijder", "Remove")} question={tr("De API-sleutel verwijderen?", "Remove the API key?")} detail={tr("De sleutel wordt uit de sleutelhanger verwijderd.", "The key is deleted from the Keychain.")} onconfirm={removeKey} />
      {:else}
        <button onclick={() => openUrl("https://developers.giphy.com/dashboard/")}>{tr("Sleutel aanvragen…", "Get a key…")}</button>
      {/if}
    </span>
  </div>
  <p class="faint small note">{tr("Alleen je zoekwoorden gaan naar giphy.com.", "Only your search words go to giphy.com.")}</p>
</Fold>

<style>
  .small { font: var(--text-detail); }
  .column { flex-direction: column; align-items: stretch; gap: var(--space-6); }
  .key input { flex: 1; }
  .note { padding: 0 var(--space-12) var(--space-8); }
</style>
