<script lang="ts">
  // Settings › Instructions (`SettingsView+Instructions` on the Mac): the default answer style and your own standing
  // instructions. Both go with every question to the brain (`nook_core::instructions`); only the voice and the length
  // change, never the facts. The text is saved when you leave the field.
  import { nook } from "../../lib/state.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import type { Settings } from "../../lib/types";
  import { toast } from "../../lib/toast.svelte";
  import { instructionsApi, partText, promptLine, type InstructionsView, type PartKind } from "../../lib/instructions";
  import ConfirmedButton from "../../components/ui/ConfirmedButton.svelte";
  import DisclosureChevron from "../../components/ui/DisclosureChevron.svelte";
  import IconButton from "../../components/ui/IconButton.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import Sheet from "../../components/ui/Sheet.svelte";

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

  // Saved prompts, spaces and the context inspector (`InstructionStore`).
  let view = $state<InstructionsView | null>(null);
  const load = () => instructionsApi.view().then((v) => (view = v)).catch(() => {});
  $effect(() => {
    load();
    const off = instructionsApi.onChanged(load);
    return () => { off.then((f) => f()); };
  });

  let addingPrompt = $state(false);
  let promptForm = $state({ title: "", trigger: "", body: "", rejected: false });
  const canSavePrompt = $derived(!!promptForm.title.trim() && !!promptForm.body.trim());
  async function savePrompt() {
    if (!canSavePrompt) return;
    const kept = await instructionsApi.savePrompt(promptForm.title, promptForm.body, promptForm.trigger);
    promptForm.rejected = !kept;
    if (kept) {
      toast.success(tr("{name} toegevoegd", "{name} added", { name: promptForm.title.trim() }));
      addingPrompt = false;
      promptForm = { title: "", trigger: "", body: "", rejected: false };
    }
  }

  let addingSpace = $state(false);
  let spaceForm = $state({ name: "", instructions: "" });
  async function saveSpace() {
    const name = spaceForm.name.trim();
    if (!name) return;
    await instructionsApi.saveSpace(name, spaceForm.instructions);
    toast.success(tr("{name} toegevoegd", "{name} added", { name }));
    addingSpace = false;
    spaceForm = { name: "", instructions: "" };
  }

  const partName = (kind: PartKind) => ({
    style: tr("Antwoordstijl", "Answer style"),
    space: tr("Instructies van de ruimte", "Space instructions"),
    memory: tr("Geheugen", "Memory"),
    lookedUp: tr("Opgezocht", "Looked up"),
    overview: tr("Overzicht en vraag", "Overview and question"),
  })[kind];
  const tokens = (n: number) => tr("~{n} tokens", "~{n} tokens", { n });
  let openParts = $state<Record<string, boolean>>({});

  async function save() {
    editing = false;
    if (text === s.instructions) return;
    await nook.saveSettings({ instructions: text });
    saved = true;
    setTimeout(() => (saved = false), 1800);
  }
</script>

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

<div class="head">
  <h3>{tr("Bewaarde prompts", "Saved prompts")}</h3>
  <span class="info" title={tr("Een variabele wordt gevraagd als je de prompt gebruikt; de tekst na | is de standaardwaarde.", "A variable is asked for when you use the prompt; the text after | is its default.")}><Ico name="info" size={13} /></span>
  <IconButton title={tr("Prompt toevoegen", "Add prompt")} onclick={() => (addingPrompt = true)}><Ico name="plus" size={14} /></IconButton>
</div>
<div class="group">
  {#if view && !view.prompts.length}
    <div class="empty"><strong>{tr("Nog geen bewaarde prompts.", "No saved prompts yet.")}</strong><span class="faint">{tr("Een bewaarde prompt is tekst die je vaak gebruikt. Typ zijn trigger na een schuine streep in een gesprek om hem in te vullen.", "A saved prompt is text you use often. Type its trigger after a slash in any conversation to fill it in.")}</span></div>
  {/if}
  {#each view?.prompts ?? [] as prompt (prompt.id)}
    <div class="row item">
      <div class="text"><span>{prompt.title}</span><span class="detail">{promptLine(prompt)}</span></div>
      <ConfirmedButton class="ghost icon" question={tr("“{name}” verwijderen?", "Remove “{name}”?", { name: prompt.title })} confirmTitle={tr("Verwijder", "Delete")} onconfirm={() => instructionsApi.removePrompt(prompt.id)}><Ico name="trash-2" size={14} /></ConfirmedButton>
    </div>
  {/each}
</div>

<div class="head">
  <h3>{tr("Ruimtes", "Spaces")}</h3>
  <span class="info" title={tr("Instructies gaan mee met elke vraag in de ruimte. Er gaat niets van deze computer weg behalve wat het gekozen brein leest.", "Instructions are sent with every question in the space. Nothing leaves this computer except what the chosen brain reads.")}><Ico name="info" size={13} /></span>
  <IconButton title={tr("Ruimte toevoegen", "Add space")} onclick={() => (addingSpace = true)}><Ico name="plus" size={14} /></IconButton>
</div>
<div class="group">
  {#if view && !view.spaces.length}
    <div class="empty"><strong>{tr("Nog geen ruimtes", "No spaces yet")}</strong><span class="faint">{tr("Een ruimte bewaart instructies die gelden voor elk gesprek dat erin staat.", "A space keeps instructions that apply to every conversation filed in it.")}</span></div>
  {/if}
  {#each view?.spaces ?? [] as space (space.id)}
    <div class="space">
      <div class="row item">
        <div class="text"><strong>{space.name}</strong><span class="detail">{tr("{n} gesprekken", "{n} conversations", { n: space.conversations })}</span></div>
        <ConfirmedButton class="ghost icon" question={tr("“{name}” verwijderen?", "Remove “{name}”?", { name: space.name })} confirmTitle={tr("Verwijder", "Delete")} onconfirm={() => instructionsApi.removeSpace(space.id)}><Ico name="trash-2" size={14} /></ConfirmedButton>
      </div>
      <textarea rows="2" value={space.instructions} placeholder={tr("Instructies voor deze ruimte", "Instructions for this space")} aria-label={tr("Instructies voor deze ruimte", "Instructions for this space")}
        onblur={(e) => e.currentTarget.value !== space.instructions && instructionsApi.saveSpace(space.name, e.currentTarget.value, space.id)}></textarea>
    </div>
  {/each}
</div>

<h3>{tr("Contextinspecteur", "Context inspector")}</h3>
<div class="group">
  {#if view?.lastContext}
    {#each view.lastContext.parts as part (part.kind)}
      <div class="part">
        <button class="part-head" aria-expanded={!!openParts[part.kind]} onclick={() => (openParts[part.kind] = !openParts[part.kind])}>
          <DisclosureChevron open={!!openParts[part.kind]} />
          <span class="text">{partName(part.kind)}</span>
          <span class="detail">{tokens(part.tokens)}</span>
        </button>
        {#if openParts[part.kind]}<pre class="code">{partText(part.text)}</pre>{/if}
      </div>
    {/each}
    <div class="row item">
      <span class="text">{tr("Totaal", "Total")}</span>
      <span class="detail">{tokens(view.lastContext.totalTokens)}{view.lastContext.fill !== null ? ` · ${view.lastContext.fill}%` : ""}</span>
    </div>
  {:else}
    <p class="faint note">{tr("Vraag Nook iets en de context van dat antwoord verschijnt hier.", "Ask Nook something and the context of that answer shows here.")}</p>
  {/if}
  <p class="faint note">{tr("Dit las het model voor het laatste antwoord. Groottes zijn schattingen.", "This is what the model read for the last answer. Sizes are estimates.")}</p>
</div>

{#if addingPrompt}
  <Sheet onclose={() => (addingPrompt = false)} label={tr("Nieuwe bewaarde prompt", "New saved prompt")}>
    <form class="form" onsubmit={(e) => { e.preventDefault(); savePrompt(); }}>
      <h2>{tr("Nieuwe bewaarde prompt", "New saved prompt")}</h2>
      <p class="faint">{tr("Een variabele wordt gevraagd als je de prompt gebruikt; de tekst na | is de standaardwaarde.", "A variable is asked for when you use the prompt; the text after | is its default.")}</p>
      <label><strong>{tr("Naam", "Name")}</strong><input bind:value={promptForm.title} /></label>
      <label><strong>{tr("Trigger", "Trigger")}</strong><input class="mono" bind:value={promptForm.trigger} placeholder={tr("Trigger zonder schuine streep (optioneel)", "Trigger without the slash (optional)")} /></label>
      <label><strong>{tr("Prompt", "Prompt")}</strong><textarea rows="5" bind:value={promptForm.body} placeholder={tr("Prompt, met {{variables}} zoals {{topic}} of {{tone|friendly}}", "Prompt, with {{variables}} such as {{topic}} or {{tone|friendly}}")}></textarea></label>
      {#if promptForm.rejected}<p class="warn">{tr("Deze prompt kon niet worden bewaard.", "This prompt could not be saved.")}</p>{/if}
      <div class="buttons">
        <button type="button" class="ghost" onclick={() => (addingPrompt = false)}>{tr("Annuleer", "Cancel")}</button>
        <button type="submit" class="primary" disabled={!canSavePrompt}>{tr("Prompt bewaren", "Save prompt")}</button>
      </div>
    </form>
  </Sheet>
{/if}

{#if addingSpace}
  <Sheet onclose={() => (addingSpace = false)} label={tr("Nieuwe ruimte", "New space")}>
    <form class="form" onsubmit={(e) => { e.preventDefault(); saveSpace(); }}>
      <h2>{tr("Nieuwe ruimte", "New space")}</h2>
      <p class="faint">{tr("Instructies gaan mee met elke vraag in de ruimte. Er gaat niets van deze computer weg behalve wat het gekozen brein leest.", "Instructions are sent with every question in the space. Nothing leaves this computer except what the chosen brain reads.")}</p>
      <label><strong>{tr("Naam", "Name")}</strong><input bind:value={spaceForm.name} placeholder={tr("Nieuwe ruimte", "New space")} /></label>
      <label><strong>{tr("Instructies", "Instructions")}</strong><textarea rows="5" bind:value={spaceForm.instructions} placeholder={tr("Instructies voor deze ruimte", "Instructions for this space")}></textarea></label>
      <div class="buttons">
        <button type="button" class="ghost" onclick={() => (addingSpace = false)}>{tr("Annuleer", "Cancel")}</button>
        <button type="submit" class="primary" disabled={!spaceForm.name.trim()}>{tr("Ruimte toevoegen", "Add space")}</button>
      </div>
    </form>
  </Sheet>
{/if}

<style>
  .head { display: flex; align-items: center; gap: var(--space-6); }
  .head h3 { flex: none; }
  .head :global(button) { margin-left: auto; }
  .info { color: var(--text3); display: inline-flex; margin-top: 14px; }
  .item { display: flex; align-items: center; gap: var(--space-8); }
  .text { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: var(--space-2); }
  .detail { font: var(--text-detail); color: var(--text2); overflow: hidden; display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; }
  .empty { display: flex; flex-direction: column; gap: var(--space-4); padding: var(--space-16) 0; font: var(--text-detail); }
  .space { padding: var(--space-8) 0; border-bottom: 1px solid var(--separator); }
  .space:last-child { border-bottom: 0; }
  .space textarea { width: 100%; resize: vertical; font: var(--text-detail); margin-bottom: var(--space-4); }
  .part { border-bottom: 1px solid var(--separator); }
  .part-head { all: unset; cursor: pointer; display: flex; align-items: center; gap: var(--space-8); width: 100%; padding: 12px 0; }
  .part-head:focus-visible { outline: 2px solid var(--iris); outline-offset: 2px; border-radius: var(--radius-chip); }
  .code { font: var(--text-code); color: var(--text2); white-space: pre-wrap; user-select: text; margin: 0 0 var(--space-8); max-height: 320px; overflow: auto; }
  .form { display: flex; flex-direction: column; gap: 12px; padding: var(--space-16); min-width: min(440px, 80vw); }
  .form h2 { margin: 0; font: var(--text-title); }
  .form label { display: flex; flex-direction: column; gap: var(--space-6); }
  .form textarea { resize: vertical; }
  .mono { font: var(--text-code); }
  .warn { color: var(--amber); font: var(--text-detail); margin: 0; }
  .buttons { display: flex; justify-content: flex-end; gap: var(--space-8); }

  .field { padding: var(--space-16) 0 var(--space-8); }
  textarea { width: 100%; resize: vertical; min-height: 120px; font: var(--text-body); }
  .foot { display: flex; justify-content: space-between; gap: var(--space-8); font: var(--text-caption); color: var(--text3); padding-top: var(--space-6); }
</style>
