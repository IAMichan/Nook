<script lang="ts">
  // De browser van Nook (`BrowserView` op de Mac). De pagina zelf staat in een eigen venster dat niets bewaart (geen
  // cookies of opslag op schijf); hier zijn het adres, terug/vooruit/opnieuw en "Lees pagina". Nook leest een pagina
  // alleen als je erom vraagt, en een agent opent er alleen een via de werkruimte (wat je ziet).
  import { tr } from "../../lib/i18n.svelte";
  import { nook } from "../../lib/state.svelte";
  import { toolEvents, toolsApi, type BrowserState } from "../../lib/workspace/api";

  let browser = $state<BrowserState | null>(null);
  let address = $state("");
  let error = $state<string | null>(null);
  let page = $state<{ title: string; url: string; text: string } | null>(null);
  let reading = $state(false);
  let editing = false;

  const available = $derived(nook.info?.capabilities.terminals ?? true);

  async function load() {
    try {
      browser = await toolsApi.browser();
      if (!editing && browser.url) address = browser.url;
    } catch (e) {
      error = String(e);
    }
  }

  $effect(() => {
    if (!available) return;
    load();
    let un: (() => void) | null = null;
    let gone = false;
    toolEvents.onBrowser(load).then((u) => (gone ? u() : (un = u)));
    return () => {
      gone = true;
      un?.();
    };
  });

  async function go() {
    error = null;
    page = null;
    editing = false;
    try {
      await toolsApi.go(address);
    } catch (e) {
      error = String(e);
    }
  }

  async function read() {
    reading = true;
    error = null;
    try {
      page = await toolsApi.read();
    } catch (e) {
      error = String(e);
    }
    reading = false;
  }

  const step = (a: "back" | "forward" | "reload") => toolsApi.step(a).catch((e) => (error = String(e)));
</script>

{#if !available}
  <div class="empty"><p>{tr("De browser van de werkruimte draait op je computer, niet op je telefoon.", "The workspace browser runs on your computer, not on your phone.")}</p></div>
{:else}
  <div class="browser">
    <div class="bar">
      <button class="ghost" title={tr("Terug", "Back")} disabled={!browser?.open} onclick={() => step("back")}>‹</button>
      <button class="ghost" title={tr("Vooruit", "Forward")} disabled={!browser?.open} onclick={() => step("forward")}>›</button>
      <button class="ghost" title={tr("Opnieuw laden", "Reload")} disabled={!browser?.open} onclick={() => step("reload")}>↻</button>
      <input bind:value={address} placeholder={tr("Adres of zoekterm", "Address or search term")} oninput={() => (editing = true)} onkeydown={(e) => e.key === "Enter" && go()} />
      <button onclick={go} disabled={!address.trim()}>{tr("Ga", "Go")}</button>
    </div>
    {#if browser?.open}
      <div class="meta">
        <span class="dot {browser.loading ? 'working' : ''}"></span>
        <span class="title">{browser.title || browser.url}</span>
        {#if browser.openedBy}<span class="faint">· {tr("Geopend door {name}", "Opened by {name}", { name: browser.openedBy })}</span>{/if}
        <span class="spacer"></span>
        <button class="ghost" onclick={read} disabled={reading}>{reading ? tr("Lezen…", "Reading…") : tr("Lees pagina", "Read page")}</button>
        <button class="ghost" onclick={() => toolsApi.closeBrowser()}>{tr("Sluit", "Close")}</button>
      </div>
    {/if}
    {#if error}<p class="err">{error}</p>{/if}
    {#if page}
      <div class="page">
        <strong>{page.title}</strong>
        <span class="faint small">{page.url}</span>
        <pre>{page.text || tr("(geen zichtbare tekst)", "(no visible text)")}</pre>
      </div>
    {:else if !browser?.open}
      <div class="empty">
        <p>{tr("De browser van Nook", "Nook's browser")}</p>
        <p class="faint">
          {tr("Typ een adres of zoekterm; de pagina opent in een eigen venster dat niets bewaart. Nook leest pagina's alleen als je erom vraagt, en opent zelf alleen pagina's na jouw goedkeuring.", "Type an address or search term; the page opens in its own window that keeps nothing. Nook only reads pages when you ask, and only opens pages itself after your approval.")}
        </p>
      </div>
    {:else}
      <p class="faint small">{tr("De pagina staat in het venster \"Nook — Browser\". Met Lees pagina zie je hier wat Nook (of een agent) ervan leest.", "The page is in the \"Nook — Browser\" window. With Read page you see here what Nook (or an agent) reads from it.")}</p>
    {/if}
  </div>
{/if}

<style>
  .browser { display: flex; flex-direction: column; gap: 8px; height: 100%; min-height: 0; }
  .bar { display: flex; gap: 4px; align-items: center; }
  .bar input { flex: 1; }
  .meta { display: flex; gap: 6px; align-items: center; font-size: 12.5px; }
  .title { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .spacer { flex: 1; }
  .page { display: flex; flex-direction: column; gap: 4px; min-height: 0; overflow: auto; border: 1px solid var(--line2); border-radius: 10px; padding: 10px; }
  .page pre { white-space: pre-wrap; font-family: var(--font); font-size: 12.5px; margin: 0; user-select: text; }
  .empty { text-align: center; padding: 24px; }
  .small { font-size: 11.5px; }
  .err { color: var(--coral); font-size: 12px; margin: 0; }
</style>
