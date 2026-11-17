<script lang="ts">
  // The one QR code for a phone to scan (`QRCodeView`): crisp pixels on a light card, named for screen readers. Give it
  // the SVG the backend made (`svg`) or an image URL (`src`); never draw a QR image by hand.
  let { svg, src, label, size = 200 }: { svg?: string; src?: string; label: string; size?: number } = $props();
</script>

<div class="qr" role="img" aria-label={label} style:width="{size}px" style:height="{size}px">
  {#if svg}{@html svg}{:else if src}<img {src} alt="" width={size} height={size} />{/if}
</div>

<style>
  .qr { flex: none; background: #fff; padding: 10px; border-radius: var(--radius-panel); overflow: hidden; box-sizing: content-box; }
  .qr :global(svg), .qr img { width: 100%; height: 100%; display: block; image-rendering: pixelated; }
</style>
