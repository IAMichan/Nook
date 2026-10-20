<script lang="ts">
  // De WhatsApp-kaart in de balk: de chat als bubbels (die van hen links, de jouwe rechts met vinkjes), foto's in de
  // bubbel en groot met een klik, bestanden die openen met de app van je computer, en een veld om meteen te antwoorden.
  // Alles uit een bericht wordt als tekst getoond, nooit als HTML.
  import { tick } from "svelte";
  import { whatsapp } from "../../lib/whatsapp.svelte";
  import { bubbleText, context, fileLabel, ticks, time } from "../../lib/whatsapp";
  import type { WhatsAppMessage } from "../../lib/connectors";
  import ServiceIcon from "./ServiceIcon.svelte";

  // `onnook`: Nook antwoordt in deze Nook (de balk toont hem).
  let { onnook }: { onnook: (nookId: string) => void } = $props();

  let scroller = $state<HTMLDivElement | null>(null);

  const card = $derived(whatsapp.card);
  const conversation = $derived(card?.conversation);
  const isGroup = $derived(conversation?.kind === "group");
  const enlarged = $derived(whatsapp.enlarged ? card?.previews[whatsapp.enlarged]?.image ?? null : null);

  // Bij een nieuwe chat of een nieuw bericht: het nieuwste onderaan in beeld; terugscrollen toont de oudere.
  let lastShown = "";
  $effect(() => {
    const messages = conversation?.messages ?? [];
    const last = messages[messages.length - 1]?.id ?? "";
    const key = `${conversation?.id}#${last}`;
    if (key === lastShown) return;
    lastShown = key;
    tick().then(() => scroller && (scroller.scrollTop = scroller.scrollHeight));
  });

  function photo(m: WhatsAppMessage): string | null {
    return m.media.kind === "image" ? card?.previews[m.id]?.image ?? null : null;
  }

  async function nook() {
    const id = await whatsapp.askNook();
    if (id) onnook(id);
  }

  function keydown(e: KeyboardEvent) {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      whatsapp.send();
    }
  }
</script>

{#if card && conversation}
  <div class="alert">
    <div class="card">
      <div class="context faint"><ServiceIcon domain="whatsapp.com" title="WhatsApp" size={16} /><span>{context(conversation.unread)}</span></div>
      <div class="title">{conversation.name}</div>
      <div class="chat" bind:this={scroller}>
        {#if conversation.messages.length > 8}<div class="older faint">Scroll omhoog voor oudere berichten</div>{/if}
        {#each conversation.messages as m (m.id)}
          {@const file = fileLabel(m.media)}
          {@const image = photo(m)}
          {@const mark = m.fromMe ? ticks(m.receipt) : null}
          {@const text = file ? m.text : bubbleText(m)}
          <div class="row" class:mine={m.fromMe}>
            <div class="bubble" class:mine={m.fromMe}>
              {#if isGroup && !m.fromMe && m.senderName}<div class="sender">{m.senderName}</div>{/if}
              {#if image}
                <button class="photo" title="Groot bekijken" onclick={() => (whatsapp.enlarged = m.id)}><img src={image} alt={file ?? "Foto"} /></button>
              {:else if file}
                <div class="file">
                  <span class="icon">{m.media.kind === "video" ? "▶" : m.media.kind === "image" ? "▣" : m.media.kind === "document" ? "▤" : "♪"}</span>
                  <span class="name">{file}</span>
                  <button class="small" onclick={() => whatsapp.open(m.id, file)}>{m.media.kind === "video" ? "Video afspelen" : "Openen"}</button>
                </div>
              {/if}
              {#if text}<div class="text">{text}</div>{/if}
              <div class="meta">{time(m.date)}{#if mark}<span class="ticks {mark.tone}" title={mark.title}>{mark.symbol}</span>{/if}</div>
            </div>
          </div>
        {/each}
      </div>
      {#if enlarged}
        <div class="large">
          <button class="photo" title="Sluit" onclick={() => (whatsapp.enlarged = null)}><img src={enlarged} alt="Foto" /></button>
          <div class="buttons">
            <button class="ghost" onclick={() => (whatsapp.enlarged = null)}>Sluit</button>
            <button onclick={() => whatsapp.enlarged && whatsapp.open(whatsapp.enlarged, "Foto")}>Openen</button>
          </div>
        </div>
      {/if}
      {#if whatsapp.notice}<div class="notice faint">{whatsapp.notice}</div>{/if}
      <div class="reply">
        <input placeholder="Antwoord {conversation.name}…" bind:value={whatsapp.draft} onkeydown={keydown} disabled={whatsapp.sending} />
        <!-- Altijd klikbaar: een leeg veld verstuurt niets. -->
        <button class="send" title="Verstuur" onclick={() => whatsapp.send()}>↑</button>
      </div>
      <div class="buttons">
        <button class="ghost" onclick={() => whatsapp.dismiss()}>Later</button>
        <button class="ghost" onclick={() => whatsapp.mute()}>Dempen</button>
        <button class="ghost" onclick={() => whatsapp.hide()}>Niet meer tonen</button>
        <span class="spacer"></span>
        <button onclick={nook}>Laat Nook antwoorden</button>
        <button class="primary" onclick={() => whatsapp.markRead()}>Gelezen</button>
      </div>
    </div>
  </div>
{/if}
{#if whatsapp.confirmation}
  <div class="toast">{whatsapp.confirmation}</div>
{/if}

<style>
  .alert { padding: 4px 12px 8px; }
  .card { position: relative; background: var(--graphite); border: 1px solid var(--line2); border-radius: 16px; padding: 12px 14px; display: flex; flex-direction: column; gap: 8px; }
  .context { display: flex; align-items: center; gap: 6px; font-size: 12px; }
  .title { font-weight: 600; font-size: 14px; line-height: 1.35; }
  .chat { max-height: 260px; overflow-y: auto; display: flex; flex-direction: column; gap: 5px; padding-right: 2px; }
  .older { font-size: 11px; text-align: center; }
  .row { display: flex; }
  .row.mine { justify-content: flex-end; }
  .bubble { max-width: 78%; background: var(--smoke); border-radius: 12px; padding: 6px 9px; display: flex; flex-direction: column; gap: 3px; user-select: text; }
  .bubble.mine { background: color-mix(in srgb, var(--mint) 22%, var(--smoke)); }
  .sender { font-size: 11px; font-weight: 600; color: var(--mint); }
  .text { font-size: 13px; line-height: 1.35; white-space: pre-wrap; overflow-wrap: anywhere; }
  .meta { align-self: flex-end; font-size: 10px; color: var(--text3); display: flex; gap: 4px; align-items: center; }
  .ticks.read { color: #53bdeb; }
  .ticks.failed { color: var(--coral); font-weight: 700; }
  .photo { padding: 0; border: none; background: none; cursor: zoom-in; display: block; }
  .photo img { display: block; max-width: 240px; max-height: 180px; border-radius: 8px; object-fit: contain; }
  .file { display: flex; align-items: center; gap: 8px; font-size: 12px; }
  .file .name { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .file .icon { color: var(--text2); }
  .small { font-size: 11px; padding: 3px 8px; }
  .large { position: absolute; inset: 0; background: var(--graphite); border-radius: 16px; padding: 12px; display: flex; flex-direction: column; gap: 8px; z-index: 2; }
  .large .photo { flex: 1; min-height: 0; cursor: zoom-out; display: flex; justify-content: center; }
  .large .photo img { max-width: 100%; max-height: 100%; }
  .notice { font-size: 12px; }
  .reply { display: flex; gap: 6px; }
  .reply input { flex: 1; }
  .send { padding: 4px 12px; font-weight: 700; }
  .buttons { display: flex; gap: 6px; flex-wrap: nowrap; }
  .buttons button { white-space: nowrap; }
  .spacer { flex: 1; }
  .toast { position: absolute; bottom: 14px; left: 50%; transform: translateX(-50%); background: var(--smoke); border: 1px solid var(--line2); border-radius: 999px; padding: 5px 14px; font-size: 12px; color: var(--mint); }
</style>
