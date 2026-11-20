<script lang="ts">
  // Active call card (`ChatCallBadge` on the Mac): floats at the bottom right while a call started from a chat lasts,
  // showing who it is with, how long it has lasted, its status (Calling / In call / Call ended), the active microphone,
  // sound output and camera, and quick Hide + Open <app> actions. Never steals focus.
  import Ico from "../../components/ui/Ico.svelte";
  import { callClock, callElapsed } from "../../lib/chats-call";
  import { activeCall } from "../../lib/chats-call.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import CallIcon from "./CallIcon.svelte";
  import ChatFace from "./ChatFace.svelte";

  $effect(() => {
    activeCall.init();
  });

  const call = $derived(activeCall.call);
  const clockText = $derived(call ? callClock(callElapsed(call, activeCall.now)) : "0:00");
  const phaseLabel = $derived.by(() => {
    if (!call) return "";
    switch (call.phase.phase) {
      case "calling": return tr("Bellen\u2026", "Calling\u2026");
      case "live": return tr("In gesprek", "In call");
      case "ended": return tr("Gesprek be\u00ebindigd", "Call ended");
    }
  });
</script>

{#if call}
  <aside class="call-card" aria-label={tr("Actief gesprek", "Active call")}>
    <div class="top">
      <ChatFace id={call.chatId} app={call.app} name={call.name} size={34} />
      <div class="who">
        <strong class="name" title={call.name}>{call.name}</strong>
        <span class="sub">
          {call.kind === "video" ? tr("Videogesprek", "Video call") : tr("Spraakoproep", "Voice call")} &middot; {call.appName}
        </span>
      </div>
      <div class="stamp">
        <span class="clock">{clockText}</span>
        <span class="phase" class:calling={call.phase.phase === "calling"} class:live={call.phase.phase === "live"} class:ended={call.phase.phase === "ended"}>{phaseLabel}</span>
      </div>
    </div>

    <div class="devices">
      <div class="device">
        <span class="dev-ico"><Ico name="mic" size={12} stroke={2.2} /></span>
        <span class="dev-label">{tr("Microfoon", "Microphone")}</span>
        <span class="dev-value" title={call.devices.microphone ?? undefined}>{call.devices.microphone ?? tr("Onbekend", "Unknown")}</span>
      </div>
      <div class="device">
        <span class="dev-ico"><Ico name="volume-2" size={12} stroke={2.2} /></span>
        <span class="dev-label">{tr("Geluid", "Sound")}</span>
        <span class="dev-value" title={call.devices.speaker ?? undefined}>{call.devices.speaker ?? tr("Onbekend", "Unknown")}</span>
      </div>
      <div class="device">
        <span class="dev-ico"><CallIcon name={call.devices.camera ? "video" : "video-off"} size={12} stroke={2.2} /></span>
        <span class="dev-label">{tr("Camera", "Camera")}</span>
        <span class="dev-value" title={call.devices.camera ?? undefined}>{call.devices.camera ?? tr("Uit", "Off")}</span>
      </div>
    </div>

    <div class="foot">
      {#if call.phase.phase === "calling" && !call.direct}
        <span class="hint">{tr("Druk op bellen in {app}. Nook volgt het gesprek.", "Press call in {app}. Nook follows the call.", { app: call.appName })}</span>
      {/if}
      <span class="spacer"></span>
      <button class="ghost" onclick={() => activeCall.dismiss()}>{tr("Verberg", "Hide")}</button>
      <button class="primary" onclick={() => activeCall.openApp()}>{tr("Open {app}", "Open {app}", { app: call.appName })}</button>
    </div>
  </aside>
{/if}

<style>
  .call-card {
    position: fixed;
    right: var(--space-16);
    bottom: var(--space-16);
    width: 300px;
    z-index: 40;
    display: flex;
    flex-direction: column;
    gap: var(--space-12);
    padding: var(--space-16);
    box-sizing: border-box;
    border-radius: var(--radius-panel);
    background: var(--canvas);
    border: 1px solid var(--line2);
    box-shadow: var(--shadow-popover);
  }
  .top { display: flex; align-items: center; gap: var(--space-12); min-width: 0; }
  .who { min-width: 0; flex: 1; display: flex; flex-direction: column; gap: var(--space-2); }
  .name { font: var(--text-strong); color: var(--paper); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .sub { font: var(--text-caption); color: var(--text3); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .stamp { flex: none; display: flex; flex-direction: column; align-items: flex-end; gap: var(--space-2); }
  .clock { font: var(--text-strong); font-variant-numeric: tabular-nums; color: var(--paper); }
  .phase { font: var(--text-caption); color: var(--text3); }
  .phase.calling { color: var(--amber); }
  .phase.live { color: var(--mint); }
  .phase.ended { color: var(--text3); }

  .devices { display: flex; flex-direction: column; gap: var(--space-4); }
  .device { display: flex; align-items: center; gap: var(--space-8); min-width: 0; }
  .dev-ico { flex: none; width: 14px; display: inline-flex; justify-content: center; color: var(--text3); }
  .dev-label { flex: none; font: var(--text-caption); color: var(--text3); }
  .dev-value { flex: 1; min-width: 0; text-align: right; font: var(--text-caption); color: var(--paper); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }

  .foot { display: flex; align-items: center; gap: var(--space-8); }
  .hint { flex: 1; min-width: 0; font: var(--text-caption); color: var(--text2); line-height: 1.3; }
  .spacer { flex: 1; }
  .foot button { flex: none; height: 26px; padding: 0 var(--space-8); border-radius: var(--radius-control); font: var(--text-label); }
  .foot .ghost { border: 0; background: transparent; color: var(--text2); }
  .foot .ghost:hover:not(:disabled) { background: var(--row-hover); color: var(--paper); }
  .foot .primary { border: 0; background: var(--mint); color: var(--ink); }
  .foot .primary:hover:not(:disabled) { opacity: 0.9; }
</style>
