<script lang="ts">
  // An answer's Markdown with the mails in it as mail cards (a ```mail block, or a quote that reads as a mail), so the
  // user can fill in what is missing and send it, as on the Mac. The text around them is the shared `Markdown` view.
  import type { InlineOptions } from "../lib/markdown-blocks";
  import { splitMailBlocks } from "../lib/mail-block";
  import { renderMarkdown } from "../lib/markdown";
  import Markdown from "./Markdown.svelte";
  import MailDraftView from "./MailDraftView.svelte";

  let {
    text,
    baseFolder = null,
    onrun,
    citation,
    html = false,
  }: {
    text: string;
    baseFolder?: string | null;
    onrun?: (command: string, title: string | null) => void;
    citation?: InlineOptions["citation"];
    /** The plain HTML renderer, for views that wrap it in a `.markdown` of their own (the companion). */
    html?: boolean;
  } = $props();
  const segments = $derived(splitMailBlocks(text));
</script>

{#each segments as segment, index (index)}
  {#if segment.kind === "markdown" && html}
    {@html renderMarkdown(segment.text)}
  {:else if segment.kind === "markdown"}
    <Markdown text={segment.text} {baseFolder} {onrun} {citation} />
  {:else}
    <MailDraftView template={segment.mail} />
  {/if}
{/each}
