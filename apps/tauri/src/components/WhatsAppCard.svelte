<script lang="ts">
  // Delegates to the unified `ChatCard` (CH-65) pinned to the WhatsApp card source so existing callers using
  // `<WhatsAppCard onnook={...} />` keep working without changes.
  import ChatCard from "./ChatCard.svelte";

  let {
    onnook,
    onopen,
    inline = false,
  }: {
    onnook: (nookId: string) => void;
    onopen?: (key: string) => void;
    inline?: boolean;
  } = $props();
</script>

<ChatCard source="whatsapp" {onnook} {onopen} {inline} />
