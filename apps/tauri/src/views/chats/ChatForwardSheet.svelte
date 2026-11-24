<script lang="ts">
  // Target-chat picker for forwarding a message (`ChatForwardPicker` on the Mac, CH-48): filters every chat Nook can
  // write in by capability (`canForwardTo`), shows a preview of the text and/or attachment, supports multi-select, and
  // forwards through `chat_forward` (falling back to `chatsApi.send` if the command is not registered yet).
  import { chatsApi, type WhatsAppMessage } from "../../lib/connectors";
  import { appName, canForwardTo, outgoingKindOfMedia, type ChatEntry } from "../../lib/chats-list";
  import { tr } from "../../lib/i18n.svelte";
  import { toast } from "../../lib/toast.svelte";
  import { fileLabel } from "../../lib/whatsapp";
  import { whatsapp } from "../../lib/whatsapp.svelte";
  import Sheet from "../../components/ui/Sheet.svelte";
  import SearchField from "../../components/ui/SearchField.svelte";
  import ListEmptyNote from "../../components/ui/ListEmptyNote.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import ChatQuote from "./ChatQuote.svelte";
  import ChatFace from "./ChatFace.svelte";
  import { invokeOrFallback } from "./chat-actions.svelte";

  interface ForwardResult {
    forwarded: string[];
    failed: { key: string; error: string }[];
  }

  let {
    sourceKey,
    messageId,
    targets,
    sender,
    text,
    media = { kind: "none" },
    onclose,
  }: {
    sourceKey: string;
    messageId: string;
    targets: ChatEntry[];
    sender: string;
    text: string;
    media?: { kind: WhatsAppMessage["media"]["kind"]; name?: string | null };
    onclose: () => void;
  } = $props();

  let query = $state("");
  let chosen = $state<string[]>([]);
  let sending = $state(false);

  const mediaKind = $derived(outgoingKindOfMedia(media));
  const mediaLabel = $derived(fileLabel(media));
  const eligible = $derived(
    targets.filter((t) => t.key !== sourceKey && canForwardTo(t, text, mediaKind)),
  );
  const shown = $derived.by(() => {
    const q = query.trim().toLowerCase();
    if (!q) return eligible;
    return eligible.filter(
      (t) => t.name.toLowerCase().includes(q) || appName(t.app).toLowerCase().includes(q),
    );
  });
  const quoteText = $derived(text.trim() || mediaLabel || "");
  const mediaIcon = $derived(
    media.kind === "image"
      ? "image"
      : media.kind === "video"
        ? "play"
        : media.kind === "audio" || media.kind === "voice"
          ? "mic"
          : "file",
  );

  function toggle(key: string) {
    chosen = chosen.includes(key) ? chosen.filter((k) => k !== key) : [...chosen, key];
  }

  async function forward() {
    if (!chosen.length || sending) return;
    sending = true;
    try {
      const result = await invokeOrFallback<ForwardResult>(
        "chat_forward",
        { sourceKey, messageId, targetKeys: chosen },
        async () => {
          const forwarded: string[] = [];
          const failed: { key: string; error: string }[] = [];
          const fallbackText = text.trim() || mediaLabel || "";
          for (const key of chosen) {
            try {
              if (!fallbackText) throw new Error(tr("Geen tekst om door te sturen", "Nothing to forward"));
              await chatsApi.send(key, fallbackText, null);
              forwarded.push(key);
            } catch (e) {
              failed.push({ key, error: String(e) });
            }
          }
          return { forwarded, failed };
        },
      );

      const names = result.forwarded
        .map((key) => targets.find((t) => t.key === key)?.name)
        .filter((n): n is string => !!n);
      if (names.length) {
        whatsapp.version++;
        toast.success(tr("Doorgestuurd naar {names}", "Forwarded to {names}", { names: names.join(", ") }));
      }
      for (const fail of result.failed) {
        toast.error(tr("Niet verstuurd: {error}", "Not sent: {error}", { error: fail.error }));
      }
      if (result.forwarded.length || !result.failed.length) {
        onclose();
      }
    } catch (e) {
      toast.error(tr("Niet verstuurd: {error}", "Not sent: {error}", { error: String(e) }));
    } finally {
      sending = false;
    }
  }
</script>

<Sheet {onclose} label={tr("Bericht doorsturen", "Forward message")}>
  <div class="head">
    <strong>{tr("Bericht doorsturen", "Forward message")}</strong>
    <span class="spacer"></span>
    <button class="ghost small" onclick={onclose} disabled={sending}>{tr("Annuleer", "Cancel")}</button>
    <button class="primary small" disabled={!chosen.length || sending} onclick={forward}>
      {chosen.length > 1
        ? tr("Doorsturen naar {n}", "Forward to {n}", { n: chosen.length })
        : tr("Doorsturen", "Forward")}
    </button>
  </div>
  <div class="quote">
    <ChatQuote {sender} text={quoteText} mine={false} />
    {#if mediaLabel && text.trim()}
      <div class="attachment">
        <Ico name={mediaIcon} size={12} />
        <span>{mediaLabel}</span>
      </div>
    {/if}
  </div>
  <div class="search">
    <SearchField bind:value={query} placeholder={tr("Zoek een chat of groep", "Search a chat or group")} />
  </div>
  <div class="list" role="listbox" aria-multiselectable="true" aria-label={tr("Kies chats", "Choose chats")}>
    {#each shown as t (t.key)}
      {@const picked = chosen.includes(t.key)}
      <button
        type="button"
        role="option"
        aria-selected={picked}
        class="row"
        class:on={picked}
        onclick={() => toggle(t.key)}
      >
        <ChatFace id={t.id} app={t.app} name={t.name} size={28} />
        <span class="name">{t.name}</span>
        <span class="app">{appName(t.app)}</span>
        <span class="box">{#if picked}<Ico name="check" size={12} stroke={3} />{/if}</span>
      </button>
    {:else}
      <ListEmptyNote
        text={eligible.length
          ? tr("Geen chat gevonden.", "No chat found.")
          : tr("Er is geen chat waarin Nook kan schrijven.", "There is no chat Nook can write in.")}
      />
    {/each}
  </div>
</Sheet>

<style>
  .head { display: flex; align-items: center; gap: var(--space-6); padding: var(--space-12) var(--space-16) var(--space-8); }
  .head strong { font: var(--text-title); color: var(--paper); }
  .spacer { flex: 1; }
  .small { height: 26px; padding: 0 var(--space-12); font: var(--text-label); font-weight: 600; }
  .quote, .search { padding: 0 var(--space-16) var(--space-8); display: flex; flex-direction: column; gap: var(--space-6); }
  .attachment { display: inline-flex; align-items: center; gap: var(--space-6); align-self: flex-start; padding: var(--space-2) var(--space-8); border-radius: var(--radius-chip); background: var(--smoke); font: var(--text-caption); color: var(--text2); }
  .list { overflow-y: auto; max-height: 50vh; padding: 0 var(--space-8) var(--space-12); display: flex; flex-direction: column; gap: var(--space-2); }
  .row { display: flex; align-items: center; gap: var(--space-8); padding: var(--space-6) var(--space-8); border: 0; border-radius: var(--radius-control); background: transparent; text-align: left; color: inherit; }
  .row:hover:not(:disabled) { background: var(--row-hover); border: 0; }
  .row.on { background: var(--row-selected); }
  .name { flex: 1; min-width: 0; font: var(--text-emphasis); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .app { font: var(--text-caption); color: var(--text3); }
  .box { width: 16px; height: 16px; display: grid; place-items: center; border: 1px solid var(--field-stroke); border-radius: 50%; color: var(--on-iris); }
  .on .box { background: var(--iris); border-color: var(--iris); }
</style>
