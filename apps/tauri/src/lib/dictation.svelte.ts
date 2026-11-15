// Dictation in the companion's composers, as the iPhone's microphone button: Android's speech recognizer (on the device
// where it can), the words landing in the field to read before you send. No audio ever goes to the computer. One
// composer listens at a time; the language is remembered.
import { appLanguage } from "./i18n.svelte";

export interface DictationEvent { state: "listening" | "partial" | "final" | "end" | "error"; text: string; onDevice: boolean }

const KEY = "companion.dictation.language";

/** The languages offered, each in its own language; empty is the phone's own. */
export const DICTATION_LANGUAGES = [
  { tag: "", name: "" },
  { tag: "en-GB", name: "English" },
  { tag: "nl-NL", name: "Nederlands" },
  { tag: "de-DE", name: "Deutsch" },
  { tag: "fr-FR", name: "Français" },
  { tag: "es-ES", name: "Español" },
];

function readLanguage(): string {
  try {
    const stored = localStorage.getItem(KEY);
    if (stored !== null) return stored;
  } catch { /* the default below */ }
  return DICTATION_LANGUAGES.find((l) => l.tag.startsWith(appLanguage()))?.tag ?? "";
}

class Dictation {
  /** The composer that listens now (an id), or null. */
  owner = $state<string | null>(null);
  onDevice = $state(true);
  language = $state(readLanguage());
  error = $state<string | null>(null);
  private listener: ((e: DictationEvent) => void) | null = null;

  get available(): boolean {
    return typeof window !== "undefined" && typeof window.NookAndroid?.dictate === "function";
  }

  setLanguage(tag: string) {
    this.language = tag;
    try { localStorage.setItem(KEY, tag); } catch { /* remembered for this visit */ }
  }

  /** Starts listening for `owner`; `onText` gets what is heard so far (partial) and then the whole of it. */
  start(owner: string, onText: (text: string, final: boolean) => void) {
    this.stop();
    this.owner = owner;
    this.error = null;
    this.listener = (e) => {
      if (e.state === "listening") this.onDevice = e.onDevice;
      else if (e.state === "partial") onText(e.text, false);
      else if (e.state === "final") onText(e.text, true);
      else if (e.state === "end") this.finish();
      else if (e.state === "error") {
        this.error = e.text;
        this.finish();
      }
    };
    window.addEventListener("nook-dictation", this.handle);
    window.NookAndroid?.dictate?.(this.language);
  }

  stop() {
    if (!this.owner) return;
    window.NookAndroid?.stopDictating?.();
    this.finish();
  }

  private finish() {
    window.removeEventListener("nook-dictation", this.handle);
    this.listener = null;
    this.owner = null;
  }

  private handle = (e: Event) => {
    const detail = (e as CustomEvent<string>).detail;
    try {
      this.listener?.(JSON.parse(detail) as DictationEvent);
    } catch { /* a malformed event says nothing */ }
  };
}

export const dictation = new Dictation();

/** The field's text with what is heard so far: after what was typed before listening started, with a space. */
export function withDictated(before: string, heard: string): string {
  if (!heard) return before;
  return before && !/\s$/.test(before) ? `${before} ${heard}` : before + heard;
}
