<script lang="ts">
  // A button for what cannot be undone (`ConfirmedButton`): it asks first in the shared dialog (`ask`), and runs
  // `onconfirm` only on the red button. Without `children` its label is `confirmTitle`; with an icon as `children`,
  // `confirmTitle` is its tooltip and what a screen reader says.
  import type { Snippet } from "svelte";
  import { ask } from "../../lib/confirm.svelte";
  let { question, detail, confirmTitle, onconfirm, children, disabled = false, class: klass = "danger" }: {
    question: string;
    detail?: string;
    confirmTitle: string;
    onconfirm: () => void | Promise<void>;
    children?: Snippet;
    disabled?: boolean;
    class?: string;
  } = $props();

  async function click() {
    if (await ask({ question, detail, confirmTitle })) await onconfirm();
  }
</script>

<button class={klass} {disabled} onclick={click} title={children ? confirmTitle : undefined} aria-label={children ? confirmTitle : undefined}>
  {#if children}{@render children()}{:else}{confirmTitle}{/if}
</button>
