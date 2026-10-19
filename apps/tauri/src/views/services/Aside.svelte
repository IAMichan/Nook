<script lang="ts">
  // Het venster naast de balk: een aanbod van meedenken als korte zin ("Zal ik dit in je agenda zetten?"), en de pil
  // van Flow terwijl je dicteert. Wijs naar het aanbod voor het hele voorstel met Doe maar, Nee of Niet in deze app.
  import { services, serviceEvents, type Nudge, type VoiceEvent } from "../../lib/services";
  import Orb from "../../components/Orb.svelte";

  let nudge = $state<Nudge | null>(null);
  let flow = $state<VoiceEvent | null>(null);
  let open = $state(false);
  let hideTimer: ReturnType<typeof setTimeout> | undefined;

  $effect(() => {
    document.body.classList.add("bar");
    services.nudge().then((n) => (nudge = n));
    const a = serviceEvents.onNudge((n) => {
      nudge = n;
      open = false;
    });
    const b = serviceEvents.onFlow((e) => {
      clearTimeout(hideTimer);
      flow = e;
      if (e.phase === "idle" || e.phase === "error") {
        hideTimer = setTimeout(() => {
          flow = null;
          if (!nudge) services.asideHide();
        }, e.phase === "error" ? 4000 : 1200);
      }
    });
    return () => {
      a.then((f) => f());
      b.then((f) => f());
    };
  });

  async function expand(on: boolean) {
    if (!nudge || open === on) return;
    open = on;
    await services.asideExpand(on);
  }

  async function answer(kind: "yes" | "open" | "no" | "mute" | "later") {
    if (!nudge) return;
    const id = nudge.id;
    open = false;
    await services.asideExpand(false);
    await services.answerNudge(id, kind);
  }

  const flowLine = $derived(
    !flow ? "" :
    flow.phase === "listening" ? (flow.text || "Luistert…") :
    flow.phase === "working" ? "Netjes maken…" :
    flow.phase === "error" ? (flow.error ?? "Dat lukte niet.") :
    flow.result ? "Geplakt" : "Niets gehoord",
  );
</script>

<div class="aside">
  {#if flow}
    <div class="pill flow" class:error={flow.phase === "error"}>
      <span class="mic" class:live={flow.phase === "listening"} style="--l:{flow.level}"></span>
      <span class="line">{flowLine}</span>
      {#if flow.phase === "listening"}
        <button class="ghost x" title="Annuleren (Esc)" onclick={() => services.flowCancel()}>✕</button>
      {/if}
    </div>
  {:else if nudge}
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <div class="card" class:open onmouseenter={() => expand(true)} onmouseleave={() => expand(false)}>
      <div class="pill">
        <Orb size={18} mood="seen" />
        <span class="line">{nudge.line}</span>
        <button class="ghost x" title="Later" onclick={() => answer("later")}>✕</button>
      </div>
      {#if open}
        <div class="detail">
          <div class="context faint">Ik dacht mee · {nudge.app}</div>
          <p>{nudge.body || "Zal ik dit voor je doen?"}</p>
          {#if nudge.actions.length}
            <ul>
              {#each nudge.actions as a (a.id)}<li>{a.tool.replaceAll("_", " ")}</li>{/each}
            </ul>
          {/if}
          <div class="buttons">
            <button class="primary" onclick={() => answer(nudge!.actions.length ? "yes" : "open")}>{nudge.actions.length ? "Doe maar" : "Handig"}</button>
            <button onclick={() => answer("no")}>Nee</button>
            <button class="ghost" onclick={() => answer("mute")}>Niet in deze app</button>
          </div>
        </div>
      {/if}
    </div>
  {/if}
</div>

<style>
  .aside { width: 100vw; height: 100vh; display: flex; align-items: flex-start; }
  .card { width: 100%; }
  .pill { display: flex; align-items: center; gap: 8px; background: var(--notch); border-radius: 999px; padding: 8px 10px 8px 12px; height: 38px; border: 1px solid var(--line2); }
  .line { flex: 1; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .x { padding: 2px 6px; font-size: 11px; }
  .card.open .pill { border-radius: 18px 18px 0 0; border-bottom-color: transparent; }
  .detail { background: var(--notch); border: 1px solid var(--line2); border-top: none; border-radius: 0 0 18px 18px; padding: 4px 14px 14px; max-height: 250px; overflow-y: auto; }
  .context { font-size: 11px; text-transform: uppercase; letter-spacing: 0.04em; }
  .detail p { margin: 6px 0; line-height: 1.45; }
  .detail ul { margin: 0 0 8px; padding-left: 18px; color: var(--text2); }
  .buttons { display: flex; gap: 6px; flex-wrap: wrap; }
  .flow .mic { width: 10px; height: 10px; border-radius: 50%; background: var(--text3); flex: none; }
  .flow .mic.live { background: var(--coral); box-shadow: 0 0 calc(4px + var(--l) * 14px) var(--coral); }
  .flow.error .line { color: var(--coral); }
</style>
