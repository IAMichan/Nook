<script lang="ts">
  // Instellingen › Aanvullen › Testen: een tekstvak om aanvullen te proberen zonder Instellingen te verlaten. Hetzelfde
  // model, dezelfde voorstellen en dezelfde emoji als in andere apps; wat je hier typt wordt niet bewaard en telt niet mee.
  import { nook } from "../../lib/state.svelte";
  import { autocomplete, nextChunk, type EmojiChoices, type PlaygroundResult } from "../../lib/autocomplete";

  const ac = $derived(nook.settings!.autocomplete);
  let text = $state("");
  let suggestion = $state("");
  let last = $state<PlaygroundResult | null>(null);
  let thinking = $state(false);
  let error = $state<string | null>(null);
  let taken = $state(0);
  let picker = $state<EmojiChoices | null>(null);
  let selected = $state(0);
  let area: HTMLTextAreaElement | undefined = $state();
  let timer: ReturnType<typeof setTimeout> | undefined;
  /// The text at the last key, to tell typing through a suggestion from typing something else.
  let previous = "";
  const columns = 9;

  function atEnd(): boolean {
    return !area || (area.selectionStart === text.length && area.selectionEnd === text.length);
  }

  async function ask(continuing = false) {
    suggestion = "";
    picker = null;
    clearTimeout(timer);
    if (!atEnd()) return;
    const before = text;
    timer = setTimeout(async () => {
      const emoji = await autocomplete.emoji(before);
      if (before !== text) return;
      if (emoji) {
        picker = emoji;
        selected = 0;
        return;
      }
      if (before.replace(/\s/g, "").length < 3) return;
      thinking = true;
      error = null;
      try {
        const result = await autocomplete.playground(before, continuing);
        if (result && before === text) {
          last = result;
          suggestion = result.shown ?? "";
        }
      } catch (e) {
        error = String(e);
      } finally {
        thinking = false;
      }
    }, 120);
  }

  function insert(value: string) {
    text += value;
    previous = text;
    taken += 1;
  }

  function takeEmoji(index: number) {
    if (!picker) return;
    const choice = picker.choices[index];
    if (!choice) return;
    text = text.slice(0, text.length - picker.query.length - 1) + choice.emoji;
    previous = text;
    picker = null;
    ask();
  }

  function onkeydown(e: KeyboardEvent) {
    if (picker) {
      const moves: Record<string, number> = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -columns, ArrowDown: columns };
      if (e.key in moves) {
        e.preventDefault();
        selected = Math.min(Math.max(selected + moves[e.key], 0), picker.choices.length - 1);
      } else if (e.key === "Tab" || (e.key === "Enter" && picker.query.length >= 2)) {
        e.preventDefault();
        takeEmoji(selected);
      } else if (/^[1-9]$/.test(e.key) && !e.ctrlKey && !e.altKey) {
        e.preventDefault();
        const index = Math.floor(selected / columns) * columns + Number(e.key) - 1;
        if (index < picker.choices.length) takeEmoji(index);
      } else if (e.key === "Escape") {
        e.preventDefault();
        picker = null;
      }
      return;
    }
    if (!suggestion) return;
    if (e.key === "Tab") {
      e.preventDefault();
      if (e.shiftKey) {
        insert(suggestion);
        suggestion = "";
        ask(true);
      } else {
        const chunk = nextChunk(suggestion, ac.punctuationWithWord, ac.trailingSpace);
        insert(chunk);
        suggestion = suggestion.slice(chunk.length);
        if (!suggestion.trim()) {
          suggestion = "";
          ask(true);
        }
      }
    } else if (e.key === "Escape") {
      e.preventDefault();
      suggestion = "";
      autocomplete.cancelPlayground();
    }
  }

  function oninput() {
    // Typing what is suggested keeps the rest.
    if (suggestion && last && text.startsWith(previous) && suggestion.startsWith(text.slice(previous.length)) && text.length > previous.length) {
      suggestion = suggestion.slice(text.length - previous.length);
      previous = text;
      if (suggestion.trim()) return;
    }
    previous = text;
    autocomplete.cancelPlayground();
    ask();
  }
</script>

<div class="box">
  <div class="mirror" aria-hidden="true">{text}<span class="ghost">{suggestion}</span></div>
  <textarea
    bind:this={area}
    bind:value={text}
    rows="5"
    placeholder="Typ hier een zin en kijk hoe Nook hem aanvult…"
    {oninput}
    {onkeydown}
  ></textarea>
</div>

{#if picker}
  <div class="picker">
    {#each picker.choices as choice, i (i)}
      <button class="cell" class:on={i === selected} title=":{choice.name}" onclick={() => takeEmoji(i)}>
        {choice.emoji}
        {#if Math.floor(i / columns) === Math.floor(selected / columns)}<span class="number">{(i % columns) + 1}</span>{/if}
      </button>
    {/each}
  </div>
  <p class="faint note">:{picker.choices[selected]?.name} · pijltjes en Tab kiezen, 1–9 in de rij, Esc sluit.</p>
{/if}

<p class="faint note">
  {ac.acceptWord || "Tab"} neemt het volgende woord, {ac.acceptAll || "Shift+Tab"} alles, Esc stuurt het weg.
  {#if thinking}Model denkt na…{/if}
  <button class="ghost" onclick={() => { text = ""; suggestion = ""; last = null; taken = 0; picker = null; }}>Wissen</button>
</p>
{#if error}<p class="err note">{error}</p>{/if}

{#if last}
  <h3>Laatste voorstel</h3>
  <div class="group">
    <div class="row"><span>Model</span><span>{last.engine}</span></div>
    <div class="row"><span>Tijd</span><span>{last.milliseconds} ms{last.confidence ? "" : " · zonder zekerheid per woord"}</span></div>
    <div class="row"><span>Antwoord van het model</span><span class="mono">{last.raw || "Geen antwoord (te onzeker)"}</span></div>
    <div class="row"><span>Getoond</span><span class="mono">{last.shown ?? "Niets"}</span></div>
    <div class="row"><span>Genomen in deze sessie</span><span>{taken}</span></div>
  </div>
  <details>
    <summary class="faint">Wat het model las</summary>
    <pre class="prompt">{last.prompt}</pre>
  </details>
{/if}

<p class="faint note">
  Hetzelfde model, dezelfde toetsen en instellingen als in andere apps. Wat je hier typt wordt niet bewaard en telt niet mee in de
  statistiek. Venster en klembord doen hier niet mee.
</p>

<style>
  .box { position: relative; margin-top: 12px; }
  .mirror, textarea {
    font: inherit;
    font-size: 14px;
    line-height: 1.5;
    padding: 10px 12px;
    box-sizing: border-box;
    width: 100%;
    white-space: pre-wrap;
    word-wrap: break-word;
  }
  .mirror { position: absolute; inset: 0; color: transparent; pointer-events: none; border: 1px solid transparent; overflow: hidden; }
  .ghost { color: var(--text2); opacity: 0.7; }
  textarea { position: relative; background: transparent; resize: vertical; }
  .picker { display: grid; grid-template-columns: repeat(9, 34px); grid-auto-rows: 34px; gap: 0; margin-top: 8px; background: var(--field); border: 1px solid var(--line); border-radius: 12px; padding: 8px; width: max-content; }
  .cell { position: relative; font-size: 20px; padding: 0; border: none; background: none; border-radius: 8px; }
  .cell.on { background: color-mix(in srgb, var(--iris) 28%, transparent); }
  .number { position: absolute; right: 3px; bottom: 1px; font-size: 9px; color: var(--text2); }
  .mono { font-family: ui-monospace, monospace; font-size: 12px; white-space: pre-wrap; text-align: right; }
  .prompt { white-space: pre-wrap; font-size: 11px; background: var(--field); border: 1px solid var(--line); border-radius: 10px; padding: 10px; max-height: 260px; overflow: auto; }
</style>
