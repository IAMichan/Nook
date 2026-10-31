<script lang="ts">
  // Logging what happened by hand: for when Nook can't see the screen, or saw it wrong. Goes into the same match
  // memory as what Nook reads from the screen.
  import { games, type Effect, type EventInput, type ValorantCatalog } from "../../lib/games";
  import { gamer } from "../../lib/gamer.svelte";
  import { tr } from "../../lib/i18n.svelte";

  let { catalog, round }: { catalog: ValorantCatalog; round: number } = $props();

  type What = "seen" | "hit" | "avoided" | "destroyed" | "death";
  let what = $state<What>("hit");
  let agent = $state("");
  let ability = $state("");
  let location = $state("");
  let timer = $state("");
  let forRound = $state<number | null>(null);

  const callouts = ["A Main", "A Short", "A Long", "A Site", "B Main", "B Short", "B Long", "B Site", "C Main", "C Site", "Mid", "Heaven", "Spawn"];
  const abilities = $derived(catalog.agents.find((a) => a.id === agent)?.abilities ?? []);
  const needsAbility = $derived(what !== "death");
  const ready = $derived(location.trim() !== "" && (!needsAbility || (agent !== "" && ability !== "")));

  $effect(() => {
    if (!abilities.some((b) => b.id === ability)) ability = abilities[0]?.id ?? "";
  });

  /// "0:06" or "6" → 6 seconds into the round.
  function seconds(text: string): number | undefined {
    const m = text.trim().match(/^(?:(\d+):)?(\d{1,3})$/);
    if (!m) return undefined;
    return (m[1] ? Number(m[1]) * 60 : 0) + Number(m[2]);
  }

  async function save() {
    const input: EventInput = what === "death"
      ? { kind: "death", side: "me", location, effect: "seen" }
      : { kind: "utility", side: "enemy", agent, ability, location, effect: what as Effect };
    input.round = forRound ?? round;
    input.roundTime = seconds(timer);
    await gamer.run(() => games.record(input), tr("Kon de gebeurtenis niet loggen", "Could not log the event"));
    timer = "";
  }
</script>

<form class="log" onsubmit={(e) => { e.preventDefault(); if (ready) save(); }}>
  <label>
    <span>{tr("Wat gebeurde er", "What happened")}</span>
    <select bind:value={what}>
      <option value="hit">{tr("Utility van de tegenstander raakte mij", "Enemy utility caught me")}</option>
      <option value="seen">{tr("Utility van de tegenstander gezien", "Enemy utility seen")}</option>
      <option value="avoided">{tr("Ik ontweek het", "I avoided it")}</option>
      <option value="destroyed">{tr("Ik heb het kapotgemaakt", "I destroyed it")}</option>
      <option value="death">{tr("Ik ging dood", "I died")}</option>
    </select>
  </label>
  {#if needsAbility}
    <label>
      <span>Agent</span>
      <select bind:value={agent}>
        <option value="" disabled>{tr("Kies", "Choose")}</option>
        {#each catalog.agents as a (a.id)}<option value={a.id}>{a.name}</option>{/each}
      </select>
    </label>
    <label>
      <span>{tr("Ability", "Ability")}</span>
      <select bind:value={ability} disabled={!agent}>
        {#each abilities as b (b.id)}<option value={b.id}>{b.slot} · {b.name}</option>{/each}
      </select>
    </label>
  {/if}
  <label>
    <span>{tr("Plek", "Location")}</span>
    <input list="valorant-callouts" bind:value={location} placeholder="B Main" maxlength="40" />
    <datalist id="valorant-callouts">{#each callouts as c (c)}<option value={c}></option>{/each}</datalist>
  </label>
  <label class="short">
    <span>{tr("Tijd in ronde", "Round time")}</span>
    <input bind:value={timer} placeholder="0:06" inputmode="numeric" />
  </label>
  <label class="short">
    <span>{tr("Ronde", "Round")}</span>
    <input type="number" min="1" max="60" placeholder={String(round)} value={forRound ?? ""} oninput={(e) => (forRound = e.currentTarget.value ? Number(e.currentTarget.value) : null)} />
  </label>
  <button class="primary" type="submit" disabled={!ready}>{tr("Onthoud", "Remember")}</button>
</form>

<style>
  .log { display: flex; flex-wrap: wrap; gap: 10px; align-items: flex-end; }
  label { display: flex; flex-direction: column; gap: 4px; font-size: 11.5px; color: var(--text3); flex: 1 1 160px; min-width: 0; }
  label.short { flex: 0 1 100px; }
  label select, label input { width: 100%; box-sizing: border-box; }
</style>
