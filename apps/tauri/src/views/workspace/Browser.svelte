<script lang="ts">
  // De browser van Nook (`BrowserView` op de Mac). De pagina zelf staat in een eigen venster dat niets bewaart (geen
  // cookies of opslag op schijf); hier zijn het adres, terug/vooruit/opnieuw, "Kies element" (AG-105) en "Lees pagina".
  // Nook leest een pagina alleen als je erom vraagt, en een agent opent er alleen een via de werkruimte (wat je ziet).
  import { invoke } from "@tauri-apps/api/core";
  import { agents } from "../../lib/agents.svelte";
  import { tr } from "../../lib/i18n.svelte";
  import { nook } from "../../lib/state.svelte";
  import { toolEvents, toolsApi, type BrowserState } from "../../lib/workspace/api";
  import { composerInbox } from "../../lib/workspace/composer-inbox.svelte";
  import { openInApi, type Visit } from "../../lib/workspace/open-in";

  interface PickedElement {
    url: string;
    selector: string;
    text: string;
    label: string;
    html: string;
    name: string;
    snippet: string;
  }

  let { session }: { session?: string } = $props();

  let browser = $state<BrowserState | null>(null);
  let address = $state("");
  let error = $state<string | null>(null);
  let page = $state<{ title: string; url: string; text: string } | null>(null);
  let reading = $state(false);
  let picking = $state(false);
  let loadingElements = $state(false);
  let pageElements = $state<PickedElement[]>([]);
  let pickedHistory = $state<PickedElement[]>([]);
  let editing = false;
  // Pages you visited before that match what you type (Settings › Sessions › Editor & browser › Remember visited pages).
  let suggestions = $state<Visit[]>([]);
  function suggest() {
    const typed = address;
    openInApi.suggest(typed).then((found) => address === typed && (suggestions = found)).catch(() => {});
  }

  const available = $derived(nook.info?.capabilities.terminals ?? true);
  const targetSession = $derived.by(() => {
    if (session) return session.replace(/^run:/, "");
    const sel = agents.selectedId;
    if (sel && sel.startsWith("run:")) return sel.slice(4);
    return undefined;
  });

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
    pageElements = [];
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

  function addSnippetToComposer(snippet: string, label: string) {
    if (targetSession) {
      composerInbox.add(snippet, targetSession);
    }
    try {
      navigator.clipboard?.writeText(snippet);
    } catch {
      // Clipboard copy is a bonus when no session composer is focused.
    }
    agents.confirm(
      targetSession
        ? tr("Element toegevoegd aan berichtenveld: {name}", "Added element to composer: {name}", { name: label })
        : tr("Element klaargezet voor berichtenveld: {name}", "Queued element for composer: {name}", { name: label }),
    );
  }

  function recordPicked(el: PickedElement) {
    pickedHistory = [el, ...pickedHistory.filter((p) => p.selector !== el.selector || p.url !== el.url)].slice(0, 12);
    addSnippetToComposer(el.snippet, el.name);
  }

  async function togglePick() {
    error = null;
    if (picking) {
      picking = false;
      await invoke("browser_cancel_pick").catch(() => {});
      return;
    }
    picking = true;
    try {
      const picked = await invoke<PickedElement | null>("browser_pick_element");
      if (picked) {
        recordPicked(picked);
      }
    } catch (e) {
      error = String(e);
    } finally {
      picking = false;
    }
  }

  async function scanElements() {
    loadingElements = true;
    error = null;
    try {
      pageElements = await invoke<PickedElement[]>("browser_elements");
    } catch (e) {
      error = String(e);
    } finally {
      loadingElements = false;
    }
  }

  async function clearPicked() {
    pickedHistory = [];
    await invoke("browser_clear_picks").catch(() => {});
  }

  function sendPageToComposer() {
    if (!page) return;
    const snippet = `[Page ${page.url}: "${page.title}"]\n${page.text.slice(0, 2000)}`;
    addSnippetToComposer(snippet, page.title || page.url);
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
      <input bind:value={address} placeholder={tr("Adres of zoekterm", "Address or search term")} list="nook-browser-visited" oninput={() => { editing = true; suggest(); }} onkeydown={(e) => e.key === "Enter" && go()} />
      <datalist id="nook-browser-visited">{#each suggestions as v (v.url)}<option value={v.url}>{v.title}</option>{/each}</datalist>
      <button onclick={go} disabled={!address.trim()}>{tr("Ga", "Go")}</button>
    </div>
    {#if browser?.open}
      <div class="meta">
        <span class="dot {browser.loading ? 'working' : ''}"></span>
        <span class="title">{browser.title || browser.url}</span>
        {#if browser.openedBy}<span class="faint">· {tr("Geopend door {name}", "Opened by {name}", { name: browser.openedBy })}</span>{/if}
        <span class="spacer"></span>
        <button
          class="ghost"
          class:picking-on={picking}
          title={picking
            ? tr("Klik op een element in het browservenster (Esc om te stoppen)", "Click an element in the browser window (Esc to cancel)")
            : tr("Wijs een element aan om naar het berichtenveld te sturen", "Point at an element to send it to the composer")}
          onclick={togglePick}
        >
          {picking ? tr("Klik in browser…", "Click in browser…") : tr("Kies element", "Pick element")}
        </button>
        <button class="ghost" onclick={scanElements} disabled={loadingElements}>
          {loadingElements ? tr("Elementen lezen…", "Reading elements…") : tr("Elementen", "Elements")}
        </button>
        <button class="ghost" onclick={read} disabled={reading}>{reading ? tr("Lezen…", "Reading…") : tr("Lees pagina", "Read page")}</button>
        <button class="ghost" onclick={() => toolsApi.closeBrowser()}>{tr("Sluit", "Close")}</button>
      </div>
    {/if}
    {#if picking}
      <div class="pick-banner">
        <span>{tr("Wijs een element aan in het venster \"Nook — Browser\" en klik erop om het in het berichtenveld te zetten.", "Point at an element in the \"Nook — Browser\" window and click it to add it to the composer.")}</span>
        <button class="ghost" onclick={togglePick}>{tr("Annuleren", "Cancel")}</button>
      </div>
    {/if}
    {#if error}<p class="err">{error}</p>{/if}
    {#if pickedHistory.length}
      <div class="picked-box">
        <div class="picked-head">
          <strong class="small">{tr("Gekozen elementen ({n})", "Picked elements ({n})", { n: pickedHistory.length })}</strong>
          <span class="spacer"></span>
          <button class="ghost small" onclick={clearPicked}>{tr("Wis", "Clear")}</button>
        </div>
        <div class="picked-list">
          {#each pickedHistory as el (el.url + "::" + el.selector)}
            <div class="picked-row">
              <div class="picked-info">
                <code class="picked-sel">{el.selector}</code>
                {#if el.label || el.text}
                  <span class="faint small picked-preview">{el.label || el.text}</span>
                {/if}
              </div>
              <button class="ghost small" onclick={() => addSnippetToComposer(el.snippet, el.name)}>
                {tr("In berichtenveld", "Add to composer")}
              </button>
            </div>
          {/each}
        </div>
      </div>
    {/if}
    {#if pageElements.length}
      <div class="picked-box">
        <div class="picked-head">
          <strong class="small">{tr("Pagina-elementen ({n})", "Page elements ({n})", { n: pageElements.length })}</strong>
          <span class="spacer"></span>
          <button class="ghost small" onclick={() => (pageElements = [])}>{tr("Verberg", "Hide")}</button>
        </div>
        <div class="picked-list">
          {#each pageElements as el (el.selector)}
            <div class="picked-row">
              <div class="picked-info">
                <code class="picked-sel">{el.selector}</code>
                {#if el.label || el.text}
                  <span class="faint small picked-preview">{el.label || el.text}</span>
                {/if}
              </div>
              <button class="ghost small" onclick={() => recordPicked(el)}>
                {tr("In berichtenveld", "Add to composer")}
              </button>
            </div>
          {/each}
        </div>
      </div>
    {/if}
    {#if page}
      <div class="page">
        <div class="picked-head">
          <strong>{page.title}</strong>
          <span class="spacer"></span>
          <button class="ghost small" onclick={sendPageToComposer}>{tr("Stuur naar berichtenveld", "Send to composer")}</button>
        </div>
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
      <p class="faint small">{tr("De pagina staat in het venster \"Nook — Browser\". Gebruik Kies element om een onderdeel in het berichtenveld te zetten, of Lees pagina om de tekst te bekijken.", "The page is in the \"Nook — Browser\" window. Use Pick element to add an element snippet to the composer, or Read page to inspect its text.")}</p>
    {/if}
  </div>
{/if}

<style>
  .browser { display: flex; flex-direction: column; gap: 8px; height: 100%; min-height: 0; }
  .bar { display: flex; gap: 4px; align-items: center; }
  .bar input { flex: 1; }
  .meta { display: flex; gap: 6px; align-items: center; font-size: 12.5px; flex-wrap: wrap; }
  .title { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .spacer { flex: 1; }
  .page { display: flex; flex-direction: column; gap: 4px; min-height: 0; overflow: auto; border: 1px solid var(--line2); border-radius: 10px; padding: 10px; }
  .page pre { white-space: pre-wrap; font-family: var(--font); font-size: 12.5px; margin: 0; user-select: text; }
  .empty { text-align: center; padding: 24px; }
  .small { font-size: 11.5px; }
  .err { color: var(--coral); font-size: 12px; margin: 0; }
  .picking-on { color: var(--mint); border-color: var(--mint); }
  .pick-banner { display: flex; align-items: center; justify-content: space-between; gap: var(--space-8); padding: var(--space-8); border-radius: var(--radius-control); background: var(--field); border: 1px solid var(--line2); font-size: var(--text-detail); }
  .picked-box { display: flex; flex-direction: column; gap: var(--space-4); border: 1px solid var(--line2); border-radius: var(--radius-card); padding: var(--space-8); background: var(--field); max-height: 220px; overflow: auto; }
  .picked-head { display: flex; align-items: center; gap: var(--space-8); }
  .picked-list { display: flex; flex-direction: column; gap: var(--space-4); }
  .picked-row { display: flex; align-items: center; justify-content: space-between; gap: var(--space-8); padding: var(--space-4) var(--space-8); border-radius: var(--radius-control); background: var(--smoke); }
  .picked-info { display: flex; flex-direction: column; gap: 2px; min-width: 0; flex: 1; }
  .picked-sel { font-family: var(--mono); font-size: var(--text-code); color: var(--paper); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .picked-preview { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
</style>
