<script lang="ts">
  // "Share with Nook" from another app, as the iPhone's share sheet: the shared text into a new session, a session that
  // exists, or a question to Nook. Nothing goes until you choose.
  import { has, may, Feature, type ClientView } from "../../lib/companion";
  import { tr } from "../../lib/i18n.svelte";
  import SettingsRow from "./ui/SettingsRow.svelte";

  let { view, text, onclose, onnew, onnook, onsession, took }: {
    view: ClientView; text: string; onclose: () => void; onnew: (task: string) => void; onnook: (text: string) => void; onsession: (id: string) => void; took?: (v: ClientView) => void;
  } = $props();
  const recent = $derived([...view.sessions].filter((s) => s.canSend !== false).sort((a, b) => b.updated - a.updated).slice(0, 5));
</script>

<div class="share">
  <div class="bar"><button class="cancel" onclick={onclose}>{tr("Annuleer", "Cancel")}</button><strong>Nook</strong><span></span></div>
  <div class="scroll">
    <p class="text">{text}</p>
    <div class="card">
      {#if has(view, Feature.start) && may(view, "operate")}<SettingsRow icon="square-pen" title={tr("Nieuwe sessie", "New session")} onclick={() => onnew(text)} />{/if}
      {#if has(view, Feature.chat) && may(view, "nookChat")}<SettingsRow icon="sparkles" title={tr("Vraag Nook", "Ask Nook")} onclick={() => onnook(text)} />{/if}
    </div>
    {#if recent.length && may(view, "operate")}
      <h3>{tr("Naar een sessie", "To a session")}</h3>
      <div class="card">
        {#each recent as s (s.id)}<SettingsRow icon="layers" title={s.title} detail={`${s.folder} · ${s.agent}`} onclick={() => onsession(s.id)} />{/each}
      </div>
    {/if}
  </div>
</div>

<style>
  .share { flex: 1; min-height: 0; display: flex; flex-direction: column; }
  .bar { display: grid; grid-template-columns: 1fr auto 1fr; align-items: center; padding: 14px 16px 8px; }
  .bar strong { font: 600 17px var(--font); }
  .cancel { justify-self: start; font: 400 17px var(--font) !important; }
  .scroll { flex: 1; overflow-y: auto; padding: 8px 16px 24px; display: flex; flex-direction: column; gap: 12px; }
  .text { margin: 0; padding: 12px; background: var(--field); border-radius: 12px; font: var(--pt-body); color: var(--text-strong); max-height: 160px; overflow-y: auto; white-space: pre-wrap; overflow-wrap: anywhere; }
  .card { background: var(--surface); border-radius: 16px; overflow: hidden; }
  h3 { margin: 8px 0 0 12px; font: var(--pt-label); color: var(--text3); }
</style>
