<script lang="ts">
  // Several questions at once, or one where several options count (the iPhone's `QuestionFlow`): one question at a time
  // with Back and Next, options to tap (a check each where several count), your own words where the agent takes them,
  // and Send on the last one, as the Mac's question card.
  import type { SessionQuestion } from "../../lib/companion";
  import { toggleAnswer, validAnswers } from "../../lib/companion-sessions";
  import { tr } from "../../lib/i18n.svelte";
  import { haptic } from "../../lib/haptics";
  import Ico from "./ui/Ico.svelte";

  let { questions, onsend }: { questions: SessionQuestion[]; onsend: (answers: Record<string, string[]>) => void } = $props();
  let step = $state(0);
  let picked = $state<Record<string, string[]>>({});
  let own = $state<Record<string, string>>({});
  const q = $derived(questions[Math.min(step, questions.length - 1)]);
  const answers = $derived(Object.fromEntries(questions.map((x) => {
    const words = (own[x.id] ?? "").trim();
    return [x.id, [...(picked[x.id] ?? []), ...(words && x.allowsOther ? [words] : [])]];
  })) as Record<string, string[]>);
  const answered = $derived((answers[q.id] ?? []).length > 0);
  const complete = $derived(validAnswers(answers, questions) !== null);

  function pick(option: string) {
    haptic();
    picked[q.id] = toggleAnswer(option, picked[q.id] ?? [], q.multiSelect);
    if (!q.multiSelect) own[q.id] = "";
  }
  function type(words: string) {
    own[q.id] = words;
    if (!q.multiSelect && words) picked[q.id] = [];
  }
</script>

<div class="flow">
  {#if questions.length > 1}<span class="step">{tr("Vraag {n} van {total}", "Question {n} of {total}", { n: step + 1, total: questions.length })}</span>{/if}
  {#if q.header}<span class="header">{q.header}</span>{/if}
  <p class="question">{q.question}</p>
  {#if q.multiSelect}<span class="step">{tr("Kies er een of meer", "Pick one or more")}</span>{/if}
  <div class="options">
    {#each q.options as option, i (option)}
      {@const on = (picked[q.id] ?? []).includes(option)}
      <button class="option press" class:on aria-pressed={on} onclick={() => pick(option)}>
        <span class="mark">{#if on}<Ico name="check" size={13} stroke={2.6} />{/if}</span>
        <span class="otext"><span>{option}</span>{#if q.previews?.[i]}<pre>{q.previews[i]}</pre>{/if}</span>
      </button>
    {/each}
  </div>
  {#if q.allowsOther}
    <textarea rows="2" placeholder={tr("Je eigen antwoord", "Your own answer")} value={own[q.id] ?? ""} oninput={(e) => type((e.currentTarget as HTMLTextAreaElement).value)}></textarea>
  {/if}
  <div class="nav">
    {#if step > 0}<button class="ghost press" onclick={() => (step -= 1)}>{tr("Terug", "Back")}</button>{/if}
    <span class="space"></span>
    {#if step < questions.length - 1}
      <button class="primary press" disabled={!answered} onclick={() => (step += 1)}>{tr("Volgende", "Next")}</button>
    {:else}
      <button class="primary press" disabled={!complete} onclick={() => { haptic("success"); onsend(validAnswers(answers, questions) ?? {}); }}>{tr("Verstuur antwoorden", "Send answers")}</button>
    {/if}
  </div>
</div>

<style>
  .flow { display: flex; flex-direction: column; gap: 10px; }
  .step { font: var(--pt-caption); color: var(--text3); }
  .header { font: var(--pt-label); color: var(--text2); }
  .question { margin: 0; font: var(--pt-strong); color: var(--paper); overflow-wrap: anywhere; }
  .options { display: flex; flex-direction: column; gap: 8px; }
  .option { display: flex; align-items: baseline; gap: 8px; min-height: 44px; padding: 9px 12px; background: var(--field) !important; border: 1px solid rgba(255, 255, 255, 0.08) !important; border-radius: 10px; text-align: left; }
  .option.on { border-color: var(--iris) !important; }
  .mark { width: 18px; height: 18px; border-radius: 5px; border: 1.5px solid var(--text3); display: inline-flex; align-items: center; justify-content: center; flex: none; color: var(--iris); }
  .option.on .mark { border-color: var(--iris); }
  .otext { display: flex; flex-direction: column; gap: 6px; font: 600 14.86px var(--font); color: var(--paper); min-width: 0; }
  .otext pre { margin: 0 0 0 12px; font: var(--pt-code); font-size: 12px; color: var(--text2); white-space: pre; overflow-x: auto; max-height: 10lh; }
  textarea { font: var(--pt-body); color: var(--paper); background: var(--field); border: none; border-radius: 10px; padding: 10px 12px; resize: none; }
  .nav { display: flex; align-items: center; gap: 8px; }
  .space { flex: 1; }
  .primary { min-height: 44px; padding: 0 18px; border-radius: 999px; background: var(--iris) !important; color: var(--on-iris, #fff) !important; font: 600 15px var(--font) !important; }
  .primary:disabled { opacity: 0.4; }
  .ghost { min-height: 44px; padding: 0 16px; border-radius: 999px; background: var(--smoke) !important; color: var(--paper) !important; font: 600 15px var(--font) !important; }
</style>
