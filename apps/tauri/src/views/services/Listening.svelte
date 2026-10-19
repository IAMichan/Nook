<script lang="ts">
  // Praten tegen Nook: "Ik luister, praat gerust", wat er gehoord is, de luidheid, en Klaar of Annuleren. Na een stilte
  // stopt Nook vanzelf; de herkende vraag gaat naar de chat, en het antwoord wordt voorgelezen als dat aanstaat.
  import { services, serviceEvents, type VoiceEvent } from "../../lib/services";
  import { api } from "../../lib/api";
  import { nook } from "../../lib/state.svelte";
  import Orb from "../../components/Orb.svelte";

  let { onclose }: { onclose: () => void } = $props();
  let voice = $state<VoiceEvent>({ phase: "listening", text: "", level: 0, error: null, result: null, seconds: 0 });
  let levels = $state<number[]>(Array(24).fill(0));
  let started = false;

  $effect(() => {
    const un = serviceEvents.onVoice(async (e) => {
      voice = e;
      levels = [...levels.slice(1), e.level];
      if (e.phase === "idle" && e.result !== null) {
        if (e.result) await send(e.result);
        onclose();
      }
    });
    if (!started) {
      started = true;
      services.voiceStart().catch((err) => (voice = { ...voice, phase: "error", error: String(err) }));
    }
    return () => {
      un.then((f) => f());
    };
  });

  async function send(text: string) {
    const id = nook.activeId ?? (await api.activeNook());
    nook.activeId = id;
    try {
      const messageId = await api.ask(id, text);
      await services.voiceFollow(id, messageId);
    } catch (e) {
      nook.error = String(e);
    }
  }

  async function cancel() {
    await services.voiceCancel();
    onclose();
  }
</script>

<div class="listening" class:error={voice.phase === "error"}>
  <Orb size={44} mood={voice.phase === "error" ? "error" : "listen"} level={voice.level} />
  <div class="body">
    <div class="context faint">{voice.phase === "working" ? "Even verstaan…" : voice.phase === "error" ? "Dat lukte niet" : "Ik luister, praat gerust"}</div>
    <div class="title">
      {#if voice.phase === "error"}{voice.error}{:else if voice.text}“{voice.text}”{:else}Zeg het maar…{/if}
    </div>
    {#if voice.phase === "listening"}
      <div class="wave" aria-hidden="true">
        {#each levels as l, i (i)}<span style="height:{3 + l * 26}px"></span>{/each}
      </div>
    {/if}
  </div>
  <div class="buttons">
    {#if voice.phase === "listening"}
      <button class="primary" onclick={() => services.voiceFinish()}>Klaar</button>
    {/if}
    <button onclick={cancel}>{voice.phase === "error" ? "Sluiten" : "Annuleren"}</button>
  </div>
</div>

<style>
  .listening { display: flex; gap: 16px; align-items: center; padding: 16px 18px; background: var(--graphite); border: 1px solid var(--line2); border-radius: var(--radius); margin: 12px; }
  .body { flex: 1; min-width: 0; }
  .context { font-size: 11px; text-transform: uppercase; letter-spacing: 0.04em; }
  .title { font-size: 15px; margin: 4px 0 8px; }
  .error .title { color: var(--coral); font-size: 13px; }
  .wave { display: flex; gap: 3px; align-items: center; height: 30px; }
  .wave span { width: 3px; border-radius: 2px; background: var(--mint); transition: height 0.1s; }
  .buttons { display: flex; flex-direction: column; gap: 6px; }
</style>
