<script lang="ts">
  // The open session's words for a screen reader (the Mac's `AgentAnnouncer`, Settings › Sessions › "Screen reader
  // announcements"): a polite aria-live region, read by Narrator and other screen readers in WebView2 and invisible
  // otherwise. What is said is decided in `lib/workspace/announcements.ts`; a step waits until the reader had time for
  // what came before it, and a newer step takes the place of one still waiting.
  import { untrack } from "svelte";
  import { announcementLevel, next, quietUntil, snapshot, type AnnounceStatus, type Memory } from "../lib/workspace/announcements";
  import type { RunEvent } from "../lib/workspace/api";
  import { workspace } from "../lib/workspace/store.svelte";

  let { sessionId, events, status, step, author }: {
    /** Switching session starts a new silent baseline. */
    sessionId: string;
    events: RunEvent[];
    status: AnnounceStatus;
    step: string | null;
    author: string;
  } = $props();

  const level = $derived(announcementLevel(workspace.settings?.screenReaderAnnouncements));
  let said = $state("");
  let memory: Memory | null = null;
  let session = "";
  let quiet = 0;
  let pending: string | null = null;
  let timer: ReturnType<typeof setTimeout> | null = null;

  function say(words: string[]) {
    if (!words.length) return;
    // A changed text is what a live region announces; the zero-width space makes a repeat count as a change.
    said = words.join(". ") + (said.endsWith("​") ? "" : "​");
    quiet = quietUntil(Date.now(), words);
  }

  function sayStepLater() {
    if (timer) clearTimeout(timer);
    timer = setTimeout(() => {
      timer = null;
      if (pending) say([pending]);
      pending = null;
    }, Math.max(0, quiet - Date.now()));
  }

  $effect(() => {
    const snap = snapshot(events, status, step);
    const lvl = level;
    const id = sessionId;
    untrack(() => {
      if (id !== session) {
        session = id;
        memory = null;
        pending = null;
      }
      const result = next(memory, snap, lvl, author);
      memory = result.memory;
      if (result.messages.length) say(result.messages);
      if (result.step) {
        pending = result.step;
        sayStepLater();
      } else if (snap.status !== "working") pending = null;
    });
  });

  $effect(() => () => { if (timer) clearTimeout(timer); });
</script>

<div class="announcer" role="status" aria-live="polite" aria-atomic="true">{level === "off" ? "" : said}</div>

<style>
  /* Heard, never seen. */
  .announcer { position: absolute; width: 1px; height: 1px; margin: -1px; padding: 0; overflow: hidden; clip-path: inset(50%); white-space: nowrap; border: 0; }
</style>
