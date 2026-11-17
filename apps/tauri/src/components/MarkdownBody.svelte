<script lang="ts">
  // An answer's Markdown with the mails in it as mail cards (a ```mail block, or a quote that reads as a mail), so the
  // user can fill in what is missing and send it, as on the Mac. Goes inside the view's own `.markdown` element.
  import { splitMailBlocks } from "../lib/mail-block";
  import { renderMarkdown } from "../lib/markdown";
  import MailDraftView from "./MailDraftView.svelte";

  let { text }: { text: string } = $props();
  const segments = $derived(splitMailBlocks(text));
</script>

{#each segments as segment, index (index)}
  {#if segment.kind === "markdown"}{@html renderMarkdown(segment.text)}{:else}<MailDraftView template={segment.mail} />{/if}
{/each}
