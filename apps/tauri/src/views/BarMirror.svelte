<script lang="ts">
  // The bar on a screen Nook is not on (`notchOnAllScreens` on the Mac): the resting round Nook, display only. Clicks
  // pass through; the real bar moves to this screen as soon as the pointer is on it.
  import Orb from "../components/Orb.svelte";

  $effect(() => {
    document.body.classList.add("bar");
  });
</script>

<div class="mirror"><span class="orbwrap"><Orb size={26} mood="rest" /></span></div>

<style>
  .mirror {
    box-sizing: border-box;
    width: 100%;
    height: 100%;
    display: flex;
    align-items: center;
    justify-content: center;
    background: var(--notch);
    border: 1px solid color-mix(in srgb, var(--paper) 12%, transparent);
    border-radius: 50%;
    overflow: hidden;
  }
  .orbwrap { display: flex; }
</style>
