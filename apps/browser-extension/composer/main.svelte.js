// The entry point `npm run build` bundles into ui/composer.js: mounts the side panel's composer and hands
// sidepanel.js a small handle to keep it up to date. sidepanel.js stays plain JavaScript; only the composer is Svelte.
import { mount } from 'svelte';
import { askedBefore } from '@nook/web-ui/recall';
import PanelComposer from './PanelComposer.svelte';

/** The questions asked in the panel's conversation, newest first, once each: what Up brings back. */
export function questionsAsked(messages) {
  return askedBefore(messages.map((message) => ({ fromUser: !message.fromNook, text: message.text || '' })));
}

/**
 * Mounts the composer in `target`. `onsend(text, images)` gets the question and its pictures
 * (`[{ mediaType, base64 }]`); `onstop` stops Nook's answer; `onnewchat` starts a new conversation.
 */
export function mountComposer(target, { onsend, onstop, onnewchat }) {
  const panel = $state({
    connected: false,
    busy: false,
    canStop: false,
    showNewChat: false,
    history: [],
    conversation: null
  });
  const component = mount(PanelComposer, { target, props: { panel, onsend, onstop, onnewchat } });
  return {
    /** Changes what the composer shows: `connected`, `busy`, `canStop`, `showNewChat`, `history`, `conversation`. */
    set(values) {
      Object.assign(panel, values);
    },
    focus() {
      component.focus();
    }
  };
}
