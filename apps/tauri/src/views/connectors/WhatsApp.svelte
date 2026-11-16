<script lang="ts">
  // WhatsApp live: via een koppeling op deze computer (GOWA of OpenWA), die WhatsApp ziet als gekoppeld apparaat.
  // Nieuwe berichten komen hier binnen; antwoorden kan meteen, en Nook mag na jouw OK een bericht sturen.
  import {
    connectorsApi,
    connectorEvents,
    gatewayAddress,
    type WhatsAppChatMode,
    type WhatsAppGateway,
    type WhatsAppConversation,
    type WhatsAppSettings,
    type WhatsAppSettingsChat,
    type WhatsAppView,
  } from "../../lib/connectors";
  import { bubbleText, fileLabel, kindLabel, modeLabel, settingsChats, ticks } from "../../lib/whatsapp";
  import { tr } from "../../lib/i18n.svelte";
  import Avatar from "./Avatar.svelte";
  import ServiceIcon from "./ServiceIcon.svelte";

  let view = $state<WhatsAppView | null>(null);
  let chats = $state<WhatsAppConversation[]>([]);
  let credential = $state("");
  let advanced = $state(false);
  let testing = $state(false);
  let testResult = $state("");
  let replies = $state<Record<string, string>>({});
  let sent = $state("");
  // Per chat: every chat with its own choice, and the hidden ones that can come back one at a time.
  let perChat = $state(false);
  let query = $state("");
  let all = $state<WhatsAppSettingsChat[]>([]);
  const listed = $derived(settingsChats(all, query));
  const modes: WhatsAppChatMode[] = ["automatic", "loud", "muted"];

  async function load() {
    view = await connectorsApi.whatsapp();
    chats = view.link.kind === "connected" ? await connectorsApi.whatsappChats() : [];
    all = view.settings.enabled ? await connectorsApi.whatsappSettingsChats() : [];
  }

  async function setMode(chat: WhatsAppSettingsChat, mode: WhatsAppChatMode) {
    await connectorsApi.whatsappSetMode(chat.jid, mode);
    await load();
  }

  /** What automatic means for this kind right now. */
  function rule(chat: WhatsAppSettingsChat): string {
    const s = view?.settings;
    const quiet = chat.kind === "group" ? s?.muteGroups : chat.kind === "status" ? s?.muteStatus : chat.kind === "channel" ? s?.muteChannels : false;
    return tr("Automatisch betekent voor deze soort nu: {mode}", "Automatic currently means for this kind: {mode}", { mode: quiet ? modeLabel.muted : modeLabel.loud });
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
      sent = tr("Verstuurd naar {name}", "Sent to {name}", { name });
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
      <span class="head"><ServiceIcon domain="whatsapp.com" title="WhatsApp" /><span><strong>{tr("WhatsApp koppelen", "Connect WhatsApp")}</strong><br /><span class="faint small">{tr("Nieuwe berichten in Nook, antwoorden vanuit Nook, en Nook mag na jouw OK een bericht sturen.", "New messages in Nook, replies from Nook, and Nook may send a message after your OK.")}</span></span></span>
      <input type="checkbox" checked={view.settings.enabled} onchange={(e) => save({ enabled: e.currentTarget.checked })} />
    </label>
    {#if view.settings.enabled}
      <div class="row">
        <span class="inline"><span class="dot {dot}"></span>{view.statusLine}</span>
        <button onclick={test} disabled={testing}>{testing ? tr("Testen…", "Testing…") : tr("Test", "Test")}</button>
      </div>
      {#if testResult}<p class="faint small">{testResult}</p>{/if}
      {#if view.webhookLine}<p class="faint small">{view.webhookLine}</p>{/if}
      {#if view.qr}
        <div class="qr">
          <img src={view.qr} alt={tr("QR-code om WhatsApp te koppelen", "QR code to connect WhatsApp")} width="200" height="200" />
          <p class="muted">{tr("Open WhatsApp op je telefoon › Instellingen › Gekoppelde apparaten › Apparaat koppelen, en scan deze code.", "Open WhatsApp on your phone › Settings › Linked devices › Link a device, and scan this code.")}</p>
        </div>
      {/if}
      <label class="row"><span>{tr("Nieuwe berichten melden", "Notify about new messages")}<br /><span class="faint small">{tr("Met de laatste regels van de chat en een veld om meteen te antwoorden.", "With the last lines of the chat and a field to reply right away.")}</span></span><input type="checkbox" checked={view.settings.notify} onchange={(e) => save({ notify: e.currentTarget.checked })} /></label>
      {#if view.settings.notify}
        <!-- De regel per soort chat, en daaronder elke chat apart: luider of stiller dan zijn soort. -->
        <label class="row"><span>{tr("Groepen stil", "Mute groups")}<br /><span class="faint small">{tr("Een groep meldt zich alleen als iemand je noemt.", "A group only notifies you when someone mentions you.")}</span></span><input type="checkbox" checked={view.settings.muteGroups} onchange={(e) => save({ muteGroups: e.currentTarget.checked })} /></label>
        <label class="row"><span>{tr("Statussen stil", "Mute statuses")}<br /><span class="faint small">{tr("Statusupdates van je contacten melden zich niet.", "Status updates from your contacts don't notify you.")}</span></span><input type="checkbox" checked={view.settings.muteStatus} onchange={(e) => save({ muteStatus: e.currentTarget.checked })} /></label>
        <label class="row"><span>{tr("Kanalen stil", "Mute channels")}<br /><span class="faint small">{tr("Kanalen die je volgt melden zich niet.", "Channels you follow don't notify you.")}</span></span><input type="checkbox" checked={view.settings.muteChannels} onchange={(e) => save({ muteChannels: e.currentTarget.checked })} /></label>
        <button class="link" onclick={() => (perChat = !perChat)}>{perChat ? "▾" : "▸"} {tr("Per chat", "Per chat")} <span class="faint small">· {tr("Kies per persoon, groep, status of kanaal: volgens de regel hierboven, altijd melden, of nooit.", "Choose per person, group, status or channel: by the rule above, always notify, or never.")}</span></button>
        {#if perChat}
          {#if all.length === 0}
            <p class="faint small">{tr("Nog geen chats. Zodra er berichten binnenkomen staan ze hier.", "No chats yet. As soon as messages come in, they appear here.")}</p>
          {:else}
            <input class="search" placeholder={tr("Zoek een chat", "Search a chat")} bind:value={query} />
            {#each listed.shown as chat (chat.jid)}
              <div class="row chatmode">
                <span class="inline"><Avatar chat={chat.jid} name={chat.name} size={22} /><span>{chat.name}<br /><span class="faint small">{kindLabel[chat.kind]}</span></span></span>
                <span class="segmented" title={rule(chat)}>
                  {#each modes as mode (mode)}
                    <button class:on={chat.mode === mode} onclick={() => setMode(chat, mode)}>{modeLabel[mode]}</button>
                  {/each}
                </span>
              </div>
            {/each}
          {/if}
          {#if listed.hidden.length}
            <p class="faint small"><strong>{tr("Verborgen chats", "Hidden chats")}</strong></p>
            {#each listed.hidden as chat (chat.jid)}
              <div class="row">
                <span class="inline"><Avatar chat={chat.jid} name={chat.name} size={22} />{chat.name}</span>
                <button onclick={async () => { await connectorsApi.whatsappUnhide(chat.jid); await load(); }}>{tr("Weer tonen", "Show again")}</button>
              </div>
            {/each}
          {/if}
        {/if}
      {/if}
      <label class="row"><span>{tr("Leesbevestiging bij antwoorden", "Read receipt when replying")}<br /><span class="faint small">{tr("Als je antwoordt of op Gelezen klikt, zie je bericht als gelezen op WhatsApp. Nooit alleen omdat het binnenkwam.", "When you reply or click Mark as read, the message shows as read on WhatsApp. Never just because it came in.")}</span></span><input type="checkbox" checked={view.settings.markReadOnReply} onchange={(e) => save({ markReadOnReply: e.currentTarget.checked })} /></label>
      <button class="link" onclick={() => (advanced = !advanced)}>{advanced ? "▾" : "▸"} {tr("Geavanceerd", "Advanced")}</button>
      {#if advanced}
        <div class="row">
          <span>{tr("Koppeling", "Gateway")}</span>
          <select value={view.settings.gateway} onchange={(e) => save({ gateway: e.currentTarget.value as WhatsAppGateway, url: "" })}>
            <option value="gowa">GOWA</option>
            <option value="openwa">OpenWA</option>
          </select>
        </div>
        <div class="row"><span>{tr("Adres", "Address")}</span><input value={view.settings.url} placeholder={gatewayAddress[view.settings.gateway]} onchange={(e) => save({ url: e.currentTarget.value })} /></div>
        <div class="row">
          <span>{view.settings.gateway === "gowa" ? tr("Gebruiker:wachtwoord (optioneel)", "User:password (optional)") : tr("API-sleutel", "API key")}</span>
          <span class="inline"><input type="password" placeholder={view.hasCredential ? tr("Bewaard in je kluis", "Stored in your keychain") : ""} bind:value={credential} /><button onclick={saveCredential} disabled={!credential.trim() && !view.hasCredential}>{credential.trim() ? tr("Bewaar", "Save") : tr("Weghalen", "Remove")}</button></span>
        </div>
        <div class="row"><span>{tr("Poort van Nooks webhook (127.0.0.1)", "Port of Nook's webhook (127.0.0.1)")}</span><input type="number" min="1024" max="65535" value={view.settings.port} onchange={(e) => save({ port: Number(e.currentTarget.value) })} /></div>
        {#if view.desktop && view.settings.gateway === "gowa"}
          <label class="row"><span>{tr("GOWA automatisch starten met Nook", "Start GOWA automatically with Nook")}<br /><span class="faint small">{view.gowaRunning ? tr("GOWA draait.", "GOWA is running.") : tr("Nook start GOWA alleen op deze computer, op 127.0.0.1, zonder media te downloaden.", "Nook starts GOWA only on this computer, on 127.0.0.1, without downloading media.")}</span></span><input type="checkbox" checked={view.settings.autoStart} onchange={(e) => save({ autoStart: e.currentTarget.checked })} /></label>
          {#if view.settings.autoStart}
            <div class="row"><span>{tr("Pad naar GOWA", "Path to GOWA")}</span><input value={view.settings.gowaPath} placeholder="~/gowa/whatsapp" onchange={(e) => save({ gowaPath: e.currentTarget.value })} /></div>
          {/if}
        {/if}
      {/if}
    {/if}
  </div>
  {#if chats.length}
    <h3>{tr("Gesprekken", "Conversations")}</h3>
    <div class="group">
      {#each chats.slice(0, 8) as chat (chat.id)}
        <div class="chat">
          <div class="inline"><strong>{chat.name}</strong>{#if chat.unread}<span class="badge">{tr("{n} nieuw", "{n} new", { n: chat.unread })}</span>{/if}<span class="spacer"></span>
            <button class="ghost small" onclick={() => connectorsApi.whatsappMarkRead(chat.id).then(load)}>{tr("Gelezen", "Mark as read")}</button>
            <button class="ghost small" onclick={() => connectorsApi.whatsappIgnore(chat.id).then(load)}>{tr("Niet meer tonen", "Stop showing")}</button>
          </div>
          {#each chat.messages.slice(-3) as m (m.id)}
            {@const mark = m.fromMe ? ticks(m.receipt) : null}
            <div class="msg"><span class="faint">{m.fromMe ? tr("Jij", "You") : m.senderName || chat.name}:</span> {[fileLabel(m.media), bubbleText(m)].filter(Boolean).join(" · ")}{#if mark}<span class="ticks {mark.tone}" title={mark.title}> {mark.symbol}</span>{/if}</div>
          {/each}
          <div class="inline"><input placeholder={tr("Antwoord {name}…", "Reply to {name}…", { name: chat.name })} bind:value={replies[chat.id]} onkeydown={(e) => e.key === "Enter" && reply(chat)} /><button onclick={() => reply(chat)} disabled={!replies[chat.id]?.trim()}>{tr("Verstuur", "Send")}</button></div>
        </div>
      {/each}
    </div>
    {#if sent}<p class="faint small">{sent}</p>{/if}
  {/if}
  <p class="faint small">{tr("WhatsApp heeft geen officiële koppeling voor een eigen account. Nook praat met een koppeling op je eigen computer (GOWA of OpenWA), die WhatsApp ziet als een gekoppeld apparaat, net als WhatsApp Web. Berichten blijven alleen in het geheugen en nooit in een logboek; een foto of bestand dat de kaart toont of dat je opent, staat even in Nooks eigen map en is weg zodra WhatsApp of Nook stopt. Nook stuurt alleen naar chats op je telefoon, hoogstens 6 per minuut, en alleen na jouw Enter of Uitvoeren. Dit is niet officieel: gebruik het met verstand.", "WhatsApp has no official connection for a personal account. Nook talks to a gateway on your own computer (GOWA or OpenWA), which WhatsApp sees as a linked device, just like WhatsApp Web. Messages stay in memory only and never in a log; a photo or file the card shows or that you open sits briefly in Nook's own folder and is gone as soon as WhatsApp or Nook stops. Nook only sends to chats on your phone, at most 6 per minute, and only after your Enter or Run. This is unofficial: use it wisely.")}</p>
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
  .search { width: 100%; margin: 4px 0; }
  .chatmode { padding: 4px 0; }
  .segmented { display: inline-flex; border: 1px solid var(--line2); border-radius: 8px; overflow: hidden; flex: none; }
  .segmented button { border: none; border-radius: 0; padding: 3px 9px; font-size: 11px; background: transparent; color: var(--text2); }
  .segmented button.on { background: var(--smoke); color: var(--paper); }
  .ticks.read { color: #53bdeb; }
  .ticks.failed { color: var(--coral); }
</style>
