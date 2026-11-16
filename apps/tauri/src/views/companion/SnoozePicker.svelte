<script lang="ts">
  // Snooze to a moment you pick, as the iPhone's sheet (`SnoozeViews`): a date and a time, from a minute and a half from
  // now up to a month ahead, an hour from now to start with.
  import { snoozeRange } from "../../lib/companion";
  import { tr } from "../../lib/i18n.svelte";
  import { haptic } from "../../lib/haptics";
  let { title, onpick, onclose }: { title: string; onpick: (seconds: number) => void; onclose: () => void } = $props();
  const local = (ms: number) => { const d = new Date(ms); d.setMinutes(d.getMinutes() - d.getTimezoneOffset()); return d.toISOString().slice(0, 16); };
  const range = snoozeRange();
  let value = $state(local(Date.now() + 3_600_000));
  const at = $derived(new Date(value).getTime());
  const valid = $derived(!Number.isNaN(at) && at >= range.min && at <= range.max);
</script>

<div class="snooze">
  <div class="bar"><button class="link" onclick={onclose}>{tr("Annuleer", "Cancel")}</button><span class="t"><strong>{tr("Sluimer", "Snooze")}</strong><small>{title}</small></span><span></span></div>
  <div class="body">
    <label><span>{tr("Wakker om", "Wake at")}</span><input type="datetime-local" bind:value min={local(range.min)} max={local(range.max)} /></label>
    <button class="primary" disabled={!valid} onclick={() => { haptic(); onpick(Math.round(at / 1000)); onclose(); }}>{tr("Sluimer", "Snooze")}</button>
  </div>
</div>

<style>
  .snooze { flex: 1; display: flex; flex-direction: column; padding-top: 10px; }
  .bar { display: grid; grid-template-columns: 1fr auto 1fr; align-items: center; padding: 8px 16px; }
  .link { justify-self: start; font: 400 17px var(--font) !important; }
  .t { display: flex; flex-direction: column; align-items: center; max-width: 240px; }
  .t strong { font: 600 17px var(--font); }
  .t small { font: var(--pt-caption); color: var(--text3); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 100%; }
  .body { padding: 16px; display: flex; flex-direction: column; gap: 16px; }
  label { display: flex; flex-direction: column; gap: 8px; font: var(--pt-label); color: var(--text2); }
  input { padding: 12px !important; background: var(--surface) !important; border-radius: 12px !important; color-scheme: dark; accent-color: var(--amber); font: var(--pt-body) !important; }
  .primary { height: 50px; border-radius: 999px; background: var(--iris) !important; color: var(--on-iris) !important; font: 600 17px var(--font) !important; }
</style>
