// The entry point `npm run build` bundles into ui/composer.js: mounts the side panel's conversation and composer (both
// Nook's shared ones from packages/web-ui) and hands sidepanel.js small handles to keep them up to date. sidepanel.js
// stays plain JavaScript; only these are Svelte.
import { mount } from 'svelte';
import { askedBefore } from '@nook/web-ui/recall';
import PanelComposer from './PanelComposer.svelte';
import PanelTranscript from './PanelTranscript.svelte';

/** The questions asked in the panel's conversation, newest first, once each: what Up brings back. */
export function questionsAsked(messages) {
  return askedBefore(messages.map((message) => ({ fromUser: !message.fromNook, text: message.text || '' })));
}

/**
 * Mounts the composer in `target`. `onsend(text, images)` gets the question and its pictures
 * (`[{ mediaType, base64 }]`); `onstop` stops Nook's answer; `onbrain` asks for the newest models when the model menu
 * opens; `onchoosebrain(id)` picks one.
 */
export function mountComposer(target, { onsend, onstop, onbrain, onchoosebrain }) {
  const panel = $state({
    connected: false,
    busy: false,
    canStop: false,
    history: [],
    conversation: null,
    brain: null
  });
  const component = mount(PanelComposer, { target, props: { panel, onsend, onstop, onbrain, onchoosebrain } });
  return {
    /** Changes what the composer shows: `connected`, `busy`, `canStop`, `history`, `conversation`, `brain`. */
    set(values) {
      Object.assign(panel, values);
    },
    focus() {
      component.focus();
    },
    fill(text) {
      component.fill(text);
    }
  };
}

/**
 * Mounts the conversation in `target`; `set(messages)` draws it again. `onreuse(text)` puts a question back in the
 * composer; `timeOf(at)` writes a message's time.
 */
export function mountTranscript(target, { onreuse, timeOf } = {}) {
  const panel = $state({ messages: [] });
  mount(PanelTranscript, { target, props: { panel, onreuse, timeOf } });
  return {
    set(messages) {
      panel.messages = messages;
    }
  };
}
