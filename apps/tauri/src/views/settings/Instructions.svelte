<script lang="ts">
  // Settings › Instructions (`SettingsView+Instructions` on the Mac): the default answer style and your own standing
  // instructions. Both go with every question to the brain (`nook_core::instructions`); only the voice and the length
  // change, never the facts. The text is saved when you leave the field.
  import { nook } from "../../lib/state.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import type { Settings } from "../../lib/types";

  const MAX = 4000;
  type Style = Settings["answerStyle"];
  const s = $derived(nook.settings!);
  const styles = $derived<{ id: Style; name: string }[]>([
    { id: "standard", name: tr("Standaard", "Standard") },
    { id: "concise", name: tr("Beknopt", "Concise") },
    { id: "explanatory", name: tr("Uitleggend", "Explanatory") },
    { id: "formal", name: tr("Formeel", "Formal") },
    { id: "casual", name: tr("Informeel", "Casual") },
  ]);

  let text = $state(nook.settings?.instructions ?? "");
  let saved = $state(false);
  // A change made elsewhere (a reset in Maintenance) shows here unless you are typing.
  let editing = $state(false);
  $effect(() => {
    const stored = nook.settings?.instructions ?? "";
    if (!editing) text = stored;
  });

  async function save() {
    editing = false;
    if (text === s.instructions) return;
    await nook.saveSettings({ instructions: text });
    saved = true;
    setTimeout(() => (saved = false), 1800);
  }
</script>

<h2>{tr("Instructies", "Instructions")}</h2>
<h3>{tr("Antwoordstijl", "Answer style")}</h3>
<div class="group">
  <label class="row">
    <span>{tr("Standaardstijl", "Default style")}</span>
    <select value={s.answerStyle} onchange={(e) => nook.saveSettings({ answerStyle: e.currentTarget.value as Style })}>
      {#each styles as st (st.id)}<option value={st.id}>{st.name}</option>{/each}
    </select>
  </label>
  <p class="faint note">{tr("Alleen de toon en de lengte veranderen, nooit de feiten.", "Only the voice and the length change, never the facts.")}</p>
</div>
<h3>{tr("Jouw instructies", "Your instructions")}</h3>
<div class="group">
  <div class="field">
    <textarea bind:value={text} rows="7" maxlength={MAX} onfocus={() => (editing = true)} onblur={save}
      aria-label={tr("Jouw instructies", "Your instructions")}
      placeholder={tr("Bijvoorbeeld: Noem me Sam. Gebruik het metrieke stelsel. Geef bij code altijd een korte uitleg.", "For example: Call me Sam. Use metric units. Always add a short explanation to code.")}></textarea>
    <div class="foot faint">
      <span>{saved ? tr("Bewaard", "Saved") : tr("Wordt bewaard als je het veld verlaat.", "Saved when you leave the field.")}</span>
      <span>{text.length} / {MAX}</span>
    </div>
  </div>
  <p class="faint note">{tr("Nook stuurt deze tekst mee met elke vraag, naar het brein dat je gekozen hebt. Wat je in een vraag zelf zegt, gaat voor. Zet hier geen wachtwoorden of sleutels in.", "Nook sends this text with every question, to the brain you chose. What you say in a question itself comes first. Don't put passwords or keys here.")}</p>
</div>

<style>
  .field { padding: var(--space-16) 0 var(--space-8); }
  textarea { width: 100%; resize: vertical; min-height: 120px; font: var(--text-body); }
  .foot { display: flex; justify-content: space-between; gap: var(--space-8); font: var(--text-caption); color: var(--text3); padding-top: var(--space-6); }
</style>
