<script lang="ts">
  // The microphone beside Send (`DictationButton`): tap to listen, tap again to stop; touch and hold for the language.
  // While it listens it shows a waveform in coral. The words land in the field; nothing is sent by dictating.
  import { dictation, DICTATION_LANGUAGES, withDictated } from "../../../lib/dictation.svelte";
  import { tr } from "../../../lib/i18n.svelte";
  import { haptic } from "../../../lib/haptics";
  import Ico from "../../../components/ui/Ico.svelte";
  import Menu from "../../../components/ui/Menu.svelte";
  let { value = $bindable("") }: { value: string } = $props();
  const id = `d${Math.random().toString(36).slice(2, 8)}`;
  const on = $derived(dictation.owner === id);
  let menu = $state<DOMRect | null>(null);
  let press: ReturnType<typeof setTimeout> | undefined;
  let held = false;
  let el = $state<HTMLButtonElement | null>(null);

  function toggle() {
    if (held) return;
    haptic();
    if (on) return dictation.stop();
    const before = value;
    dictation.start(id, (heard) => (value = withDictated(before, heard)));
  }
</script>

{#if dictation.available}
  <button bind:this={el} class="mic" class:on aria-label={on ? tr("Stop dicteren", "Stop dictation") : tr("Dicteren", "Dictate")}
    onclick={(e) => { e.stopPropagation(); toggle(); }}
    onpointerdown={() => { held = false; press = setTimeout(() => { held = true; if (el) menu = el.getBoundingClientRect(); }, 450); }}
    onpointerup={() => clearTimeout(press)} onpointerleave={() => clearTimeout(press)} oncontextmenu={(e) => e.preventDefault()}>
    <Ico name={on ? "audio-waveform" : "mic"} size={15} stroke={2.2} />
  </button>
{/if}
{#if menu}
  <Menu title={tr("Dicteertaal", "Dictation language")} anchor={menu} onclose={() => (menu = null)} sections={[
    DICTATION_LANGUAGES.map((l) => ({ label: l.name || tr("Taal van de telefoon", "The phone's language"), checked: dictation.language === l.tag, onselect: () => dictation.setLanguage(l.tag) })),
    ...(!dictation.onDevice ? [[{ label: tr("Deze taal wordt door de spraakdienst van Google gehoord, niet op deze telefoon.", "This language is heard by Google's speech service, not on this phone.") }]] : []),
  ]} />
{/if}

<style>
  .mic { width: 34px; height: 34px; border-radius: 50%; display: inline-flex; align-items: center; justify-content: center; color: var(--text2) !important; flex: none; -webkit-touch-callout: none; }
  .mic.on { color: var(--coral) !important; background: rgba(255, 100, 103, 0.22) !important; }
</style>
