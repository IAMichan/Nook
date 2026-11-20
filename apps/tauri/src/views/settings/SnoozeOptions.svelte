<script lang="ts">
  // Settings › Notifications › Snooze options (the Mac's `SnoozeOptionsSection`): what every snooze menu offers, as
  // durations and times of day, in the order they come up; add one, remove one, or go back to the defaults.
  import { tr } from "../../lib/i18n.svelte";
  import { DEFAULT_OPTIONS, loadOptions, optionId, optionLabel, saveOptions, type SnoozeDay, type SnoozeOption } from "../../lib/snooze-options";
  import Ico from "../../components/ui/Ico.svelte";

  let options = $state<SnoozeOption[]>(loadOptions());
  let kind = $state<"duration" | "time">("duration");
  let amount = $state(3);
  let unit = $state<1 | 60 | 1440>(60);
  let day = $state<SnoozeDay>("tomorrow");
  let time = $state("09:00");

  function store(next: SnoozeOption[]) {
    saveOptions(next);
    options = loadOptions();
  }
  function add() {
    const [h, m] = time.split(":").map(Number);
    const draft: SnoozeOption = kind === "duration" ? { kind, minutes: Math.max(1, Math.round(amount)) * unit } : { kind, day, hour: h || 0, minute: m || 0 };
    store([...options.filter((o) => optionId(o) !== optionId(draft)), draft]);
  }
  const days: [SnoozeDay, string][] = [
    ["today", tr("Vandaag", "Today")], ["tomorrow", tr("Morgen", "Tomorrow")],
    ...(["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"] as SnoozeDay[]).map((d, i): [SnoozeDay, string] => [d, new Date(2024, 0, 1 + i).toLocaleDateString(undefined, { weekday: "long" })]),
  ];
</script>

<h3>{tr("Snooze-opties", "Snooze options")}</h3>
<p class="section-info">{tr("Wat elk snooze-menu aanbiedt: een duur of een tijdstip.", "What every snooze menu offers: a duration or a time of day.")}</p>
<div class="group">
  {#each options as o (optionId(o))}
    <div class="row">
      <span>{optionLabel(o)}</span>
      <button class="ghost small" disabled={options.length <= 1} aria-label={tr("Verwijder", "Remove")} onclick={() => store(options.filter((x) => optionId(x) !== optionId(o)))}><Ico name="x" size={12} /></button>
    </div>
  {/each}
  <div class="row add">
    <select bind:value={kind} aria-label={tr("Soort", "Kind")}>
      <option value="duration">{tr("Duur", "Duration")}</option>
      <option value="time">{tr("Tijdstip", "Time of day")}</option>
    </select>
    {#if kind === "duration"}
      <input type="number" min="1" max="999" bind:value={amount} aria-label={tr("Hoeveel", "How many")} />
      <select bind:value={unit} aria-label={tr("Eenheid", "Unit")}>
        <option value={1}>{tr("minuten", "minutes")}</option>
        <option value={60}>{tr("uur", "hours")}</option>
        <option value={1440}>{tr("dagen", "days")}</option>
      </select>
    {:else}
      <select bind:value={day} aria-label={tr("Dag", "Day")}>{#each days as [d, label] (d)}<option value={d}>{label}</option>{/each}</select>
      <input type="time" bind:value={time} aria-label={tr("Tijd", "Time")} />
    {/if}
    <span class="spacer"></span>
    <button onclick={add}>{tr("Toevoegen", "Add")}</button>
  </div>
  <div class="row"><span></span><button class="ghost small" onclick={() => store(DEFAULT_OPTIONS)}>{tr("Standaard terugzetten", "Restore defaults")}</button></div>
</div>

<style>
  .add { justify-content: flex-start; gap: var(--space-6); flex-wrap: wrap; }
  .add input[type="number"] { width: 64px; }
  .spacer { flex: 1; }
  .small { padding: var(--space-2) var(--space-8); font: var(--text-detail); }
</style>
