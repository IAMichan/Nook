<script lang="ts">
  // De telefoonkant van de companion (zoals Nook Companion op de iPhone): koppelen met een Mac of pc, zien welke
  // sessies je nodig hebben, en goedkeuren, antwoorden, een bericht sturen of stoppen.
  import { companion, sortSessions, type ClientView } from "../../lib/companion";
  import { onBack } from "../../lib/mobile";
  import Pairing from "./Pairing.svelte";
  import SessionRow from "./SessionRow.svelte";
  import SessionDetail from "./SessionDetail.svelte";

  let view = $state<ClientView | null>(null);
  let open = $state<string | null>(null);
  let menu = $state(false);
  let refreshing = $state(false);

  $effect(() => {
    companion.client().then((v) => (view = v));
    companion.refresh().then((v) => (view = v));
    const un = companion.onClient((v) => (view = { ...v, deviceName: view?.deviceName }));
    const visible = () => companion.visible(document.visibilityState === "visible");
    document.addEventListener("visibilitychange", visible);
    visible();
    return () => {
      un.then((f) => f());
      document.removeEventListener("visibilitychange", visible);
    };
  });

  // De terugknop sluit eerst het menu, dan de sessie.
  $effect(() => onBack(() => {
    if (menu) return (menu = false), true;
    if (open) return (open = null), true;
    return false;
  }));

  const sessions = $derived(sortSessions(view?.sessions ?? []));
  const session = $derived(open ? view?.sessions.find((s) => s.id === open) ?? null : null);
  const paired = $derived(view && (view.phase === "connected" || view.phase === "offline"));

  async function act(f: () => Promise<ClientView>) {
    const v = await f();
    view = { ...v, deviceName: view?.deviceName };
  }

  async function refresh() {
    refreshing = true;
    await act(companion.refresh);
    refreshing = false;
  }
</script>

<div class="companion">
  {#if !view}
    <p class="faint pad">Laden…</p>
  {:else if !paired}
    <Pairing {view} onchange={(v) => (view = v)} />
  {:else if open}
    <SessionDetail {session} onback={() => (open = null)} {act} />
  {:else}
    <header>
      <h2>{view.macName || "Nook"}</h2>
      <button class="ghost icon" title="Ververs" disabled={refreshing} onclick={refresh}>↻</button>
      <button class="ghost icon" title="Meer" onclick={() => (menu = !menu)}>⋯</button>
    </header>
    {#if menu}
      <div class="menu">
        <button class="danger" onclick={() => { menu = false; act(async () => companion.unpair()); }}>Ontkoppel van {view.macName || "deze computer"}</button>
      </div>
    {/if}
    <div class="list">
      {#if view.phase === "offline"}
        <div class="banner">📡 {view.reason || "Zoeken naar je computer…"}</div>
      {/if}
      {#each sessions as s (s.id)}
        <SessionRow session={s} onopen={() => (open = s.id)} {act} />
      {:else}
        {#if view.phase === "connected"}<p class="faint pad">Geen sessies.</p>{/if}
      {/each}
    </div>
  {/if}
  {#if view?.notice}
    <div class="notice" role="alert">
      <span>{view.notice}</span>
      <button onclick={() => { companion.clearNotice(); if (view) view.notice = null; }}>OK</button>
    </div>
  {/if}
</div>

<style>
  .companion { height: 100%; display: flex; flex-direction: column; min-height: 0; position: relative; }
  header { display: flex; align-items: center; gap: 4px; padding: 12px 12px 8px 16px; border-bottom: 1px solid var(--line); }
  header h2 { flex: 1; margin: 0; font-size: 17px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .icon { min-width: 44px; min-height: 44px; font-size: 18px; }
  .menu { padding: 8px 12px; border-bottom: 1px solid var(--line); }
  .menu button { width: 100%; min-height: 44px; }
  .list { flex: 1; overflow-y: auto; padding: 6px 0 16px; }
  .banner { margin: 8px 12px; padding: 10px 12px; border-radius: 10px; background: var(--field); border: 1px solid var(--line2); color: var(--amber); }
  .pad { padding: 16px; }
  .notice {
    position: absolute; left: 12px; right: 12px; bottom: 12px; display: flex; gap: 10px; align-items: center;
    background: var(--smoke); border: 1px solid var(--line2); border-radius: 12px; padding: 10px 12px; box-shadow: 0 6px 24px #0008;
  }
  .notice span { flex: 1; }
  .notice button { min-height: 40px; }
</style>
