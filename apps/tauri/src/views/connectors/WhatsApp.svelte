<script lang="ts">
  // WhatsApp live: via een koppeling op deze computer (GOWA of OpenWA), die WhatsApp ziet als gekoppeld apparaat.
  // Nieuwe berichten komen hier binnen; antwoorden kan meteen, en Nook mag na jouw OK een bericht sturen.
  import { connectorsApi, connectorEvents, type WhatsAppConversation, type WhatsAppSettings, type WhatsAppView } from "../../lib/connectors";
  import ServiceIcon from "./ServiceIcon.svelte";

  let view = $state<WhatsAppView | null>(null);
  let chats = $state<WhatsAppConversation[]>([]);
  let credential = $state("");
  let advanced = $state(false);
  let testing = $state(false);
  let testResult = $state("");
  let replies = $state<Record<string, string>>({});
  let sent = $state("");

  async function load() {
    view = await connectorsApi.whatsapp();
    chats = view.link.kind === "connected" ? await connectorsApi.whatsappChats() : [];
  }

  $effect(() => {
    load();
    const a = connectorEvents.onChanged(load);
    const b = connectorEvents.onWhatsApp(load);
    // Tijdens het koppelen ververst de QR-code vanzelf.
    const timer = setInterval(() => view?.settings.enabled && view.link.kind !== "connected" && load(), 4000);
    return () => {
      a.then((f) => f());
      b.then((f) => f());
      clearInterval(timer);
    };
  });

  async function save(patch: Partial<WhatsAppSettings>) {
    if (!view) return;
    await connectorsApi.whatsappSave({ ...view.settings, ...patch });
    await load();
  }

  async function saveCredential() {
    await connectorsApi.whatsappCredential(credential);
    credential = "";
    await load();
  }

  async function test() {
    testing = true;
    testResult = await connectorsApi.whatsappTest();
    testing = false;
  }

  async function reply(chat: WhatsAppConversation) {
    const text = replies[chat.id]?.trim();
    if (!text) return;
    try {
      const name = await connectorsApi.whatsappReply(chat.id, text);
      replies[chat.id] = "";
      sent = `Verstuurd naar ${name}`;
      await load();
    } catch (e) {
      sent = String(e);
    }
  }

  const dot = $derived(view?.link.kind === "connected" ? "unread" : view?.link.kind === "needsQr" || view?.link.kind === "connecting" ? "waiting" : view?.settings.enabled ? "error" : "");
</script>

{#if view}
  <div class="group">
    <label class="row">
      <span class="head"><ServiceIcon domain="whatsapp.com" title="WhatsApp" /><span><strong>WhatsApp koppelen</strong><br /><span class="faint small">Nieuwe berichten in Nook, antwoorden vanuit Nook, en Nook mag na jouw OK een bericht sturen.</span></span></span>
      <input type="checkbox" checked={view.settings.enabled} onchange={(e) => save({ enabled: e.currentTarget.checked })} />
    </label>
    {#if view.settings.enabled}
      <div class="row">
        <span class="inline"><span class="dot {dot}"></span>{view.statusLine}</span>
        <button onclick={test} disabled={testing}>{testing ? "Testen…" : "Test"}</button>
      </div>
      {#if testResult}<p class="faint small">{testResult}</p>{/if}
      {#if view.webhookLine}<p class="faint small">{view.webhookLine}</p>{/if}
      {#if view.qr}
        <div class="qr">
          <img src={view.qr} alt="QR-code om WhatsApp te koppelen" width="200" height="200" />
          <p class="muted">Open WhatsApp op je telefoon › Instellingen › Gekoppelde apparaten › Apparaat koppelen, en scan deze code.</p>
        </div>
      {/if}
      <label class="row"><span>Nieuwe berichten melden<br /><span class="faint small">Met de laatste regels van de chat en een veld om meteen te antwoorden.</span></span><input type="checkbox" checked={view.settings.notify} onchange={(e) => save({ notify: e.currentTarget.checked })} /></label>
      <label class="row"><span>Groepen stil<br /><span class="faint small">Een groep meldt zich alleen als iemand je noemt.</span></span><input type="checkbox" checked={view.settings.muteGroups} onchange={(e) => save({ muteGroups: e.currentTarget.checked })} /></label>
      <label class="row"><span>Leesbevestiging bij antwoorden<br /><span class="faint small">Als je antwoordt of op Gelezen klikt, zie je bericht als gelezen op WhatsApp. Nooit alleen omdat het binnenkwam.</span></span><input type="checkbox" checked={view.settings.markReadOnReply} onchange={(e) => save({ markReadOnReply: e.currentTarget.checked })} /></label>
      {#if view.hiddenChats > 0}
        <div class="row"><span class="faint">{view.hiddenChats} verborgen chats</span><button onclick={async () => { await connectorsApi.whatsappUnmute(); await load(); }}>Weer tonen</button></div>
      {/if}
      <button class="link" onclick={() => (advanced = !advanced)}>{advanced ? "▾" : "▸"} Geavanceerd</button>
      {#if advanced}
        <div class="row">
          <span>Koppeling</span>
          <select value={view.settings.gateway} onchange={(e) => save({ gateway: e.currentTarget.value as "gowa" | "openwa", url: "" })}>
            <option value="gowa">GOWA</option>
            <option value="openwa">OpenWA</option>
          </select>
        </div>
        <div class="row"><span>Adres</span><input value={view.settings.url} placeholder={view.settings.gateway === "gowa" ? "http://127.0.0.1:3000" : "http://127.0.0.1:2785"} onchange={(e) => save({ url: e.currentTarget.value })} /></div>
        <div class="row">
          <span>{view.settings.gateway === "gowa" ? "Gebruiker:wachtwoord (optioneel)" : "API-sleutel"}</span>
          <span class="inline"><input type="password" placeholder={view.hasCredential ? "Bewaard in je kluis" : ""} bind:value={credential} /><button onclick={saveCredential} disabled={!credential.trim() && !view.hasCredential}>{credential.trim() ? "Bewaar" : "Weghalen"}</button></span>
        </div>
        <div class="row"><span>Poort van Nooks webhook (127.0.0.1)</span><input type="number" min="1024" max="65535" value={view.settings.port} onchange={(e) => save({ port: Number(e.currentTarget.value) })} /></div>
        {#if view.desktop && view.settings.gateway === "gowa"}
          <label class="row"><span>GOWA automatisch starten met Nook<br /><span class="faint small">{view.gowaRunning ? "GOWA draait." : "Nook start GOWA alleen op deze computer, op 127.0.0.1, zonder media te downloaden."}</span></span><input type="checkbox" checked={view.settings.autoStart} onchange={(e) => save({ autoStart: e.currentTarget.checked })} /></label>
          {#if view.settings.autoStart}
            <div class="row"><span>Pad naar GOWA</span><input value={view.settings.gowaPath} placeholder="~/gowa/whatsapp" onchange={(e) => save({ gowaPath: e.currentTarget.value })} /></div>
          {/if}
        {/if}
      {/if}
    {/if}
  </div>
  {#if chats.length}
    <h3>Gesprekken</h3>
    <div class="group">
      {#each chats.slice(0, 8) as chat (chat.id)}
        <div class="chat">
          <div class="inline"><strong>{chat.name}</strong>{#if chat.unread}<span class="badge">{chat.unread} nieuw</span>{/if}<span class="spacer"></span>
            <button class="ghost small" onclick={() => connectorsApi.whatsappMarkRead(chat.id).then(load)}>Gelezen</button>
            <button class="ghost small" onclick={() => connectorsApi.whatsappIgnore(chat.id).then(load)}>Niet meer tonen</button>
          </div>
          {#each chat.messages.slice(-3) as m (m.id)}
            <div class="msg"><span class="faint">{m.fromMe ? "Jij" : m.senderName || chat.name}:</span> {m.text}</div>
          {/each}
          <div class="inline"><input placeholder="Antwoord {chat.name}…" bind:value={replies[chat.id]} onkeydown={(e) => e.key === "Enter" && reply(chat)} /><button onclick={() => reply(chat)} disabled={!replies[chat.id]?.trim()}>Verstuur</button></div>
        </div>
      {/each}
    </div>
    {#if sent}<p class="faint small">{sent}</p>{/if}
  {/if}
  <p class="faint small">WhatsApp heeft geen officiële koppeling voor een eigen account. Nook praat met een koppeling op je eigen computer (GOWA of OpenWA), die WhatsApp ziet als een gekoppeld apparaat, net als WhatsApp Web. Berichten blijven alleen in het geheugen en nooit in een logboek. Nook stuurt alleen naar chats op je telefoon, hoogstens 6 per minuut, en alleen na jouw Enter of Uitvoeren. Dit is niet officieel: gebruik het met verstand.</p>
{/if}

<style>
  .head { display: flex; gap: 12px; align-items: center; }
  .small { font-size: 11px; }
  .qr { display: flex; gap: 16px; align-items: center; padding: 10px 0; }
  .qr img { background: white; border-radius: 10px; padding: 6px; }
  .link { background: none; border: none; padding: 8px 0; color: var(--text2); text-align: left; }
  .chat { padding: 10px 0; border-bottom: 1px solid var(--line); display: flex; flex-direction: column; gap: 4px; }
  .chat:last-child { border-bottom: none; }
  .msg { font-size: 12px; user-select: text; }
  .badge { font-size: 10px; background: var(--mint); color: var(--ink); border-radius: 8px; padding: 1px 6px; }
  .spacer { flex: 1; }
  .chat input { flex: 1; }
</style>
