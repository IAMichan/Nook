<script lang="ts">
  // Terwijl de Notetaker opneemt: een kleine pil rechtsonder met de tijd en Stop, zodat je altijd ziet dat een gesprek
  // genoteerd wordt (RecordingBadge op de Mac). Neemt nooit de focus.
  import { services, serviceEvents, clock, type NoteLive } from "../../lib/services";

  let live = $state<NoteLive | null>(null);
  let started = $state(Date.now());
  let now = $state(Date.now());

  $effect(() => {
    document.body.classList.add("bar");
    services.noteLive().then((l) => {
      live = l;
      started = Date.now() - l.seconds * 1000;
    });
    const un = serviceEvents.onNoteLive((l) => {
      if (!live?.recording && l.recording) started = Date.now() - l.seconds * 1000;
      live = l;
    });
    const timer = setInterval(() => (now = Date.now()), 1000);
    return () => {
      un.then((f) => f());
      clearInterval(timer);
    };
  });
</script>

<div class="badge">
  <span class="dot" style="opacity:{0.55 + 0.45 * Math.min(1, (live?.level ?? 0) * 12)}"></span>
  <strong>{clock((now - started) / 1000)}</strong>
  <span class="faint">Opname{live && !live.systemAudio ? " · alleen microfoon" : ""}</span>
  <span class="spacer"></span>
  <button onclick={() => services.toggleNote()}>Stop</button>
</div>

<style>
  .badge { display: flex; align-items: center; gap: 8px; height: 100vh; padding: 0 8px 0 12px; background: rgba(0, 0, 0, 0.88); border-radius: 999px; border: 1px solid var(--line2); }
  .dot { width: 9px; height: 9px; border-radius: 50%; background: #ff5a52; }
  strong { font-variant-numeric: tabular-nums; font-size: 12px; }
  .faint { font-size: 12px; white-space: nowrap; }
  .spacer { flex: 1; }
  button { padding: 3px 10px; border-radius: 999px; font-size: 12px; font-weight: 600; background: rgba(255, 255, 255, 0.16); border: none; }
</style>
