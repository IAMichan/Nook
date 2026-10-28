// The WhatsApp card in the bar (the Mac's notch card): a new message brings up its chat as bubbles, with a field to
// answer. What you type goes to that chat when you press Enter or click the arrow (your own words, your own click);
// "Laat Nook antwoorden" hands only that chat to Nook, who proposes an answer as a plan you approve.
import { connectorEvents, connectorsApi, type WhatsAppCard } from "./connectors";
import { toast } from "./toast.svelte";

class WhatsAppCardState {
  /** The chat whose card shows, or null. */
  chat = $state<string | null>(null);
  card = $state<WhatsAppCard | null>(null);
  /** What the card says it is doing (sending, opening a file) or why it failed. */
  notice = $state("");
  draft = $state("");
  sending = $state(false);
  /** The photo shown large over the chat (a message id). */
  enlarged = $state<string | null>(null);
  /** Counts what changes a chat's standing (read, muted, hidden, answered), so lists redraw at once. */
  version = $state(0);
  private started = false;

  start() {
    if (this.started) return;
    this.started = true;
    connectorEvents.onWhatsApp((arrived) => {
      // Someone typing in a card keeps it; a new message never takes it away.
      if (this.chat && this.chat !== arrived.chat && this.draft.trim()) return;
      this.show(arrived.chat);
    });
    // New ticks redraw the card on screen; they never bring one up by themselves.
    connectorEvents.onWhatsAppReceipt((chat) => chat === this.chat && this.reload());
    connectorEvents.onChanged(() => this.chat && this.reload());
  }

  async show(chat: string) {
    if (this.chat !== chat) {
      this.notice = "";
      this.draft = "";
      this.enlarged = null;
    }
    this.chat = chat;
    await this.reload();
    // Older messages (once per chat) and the newest photos, videos and documents, then drawn again.
    try {
      if (await connectorsApi.whatsappCardLoad(chat)) await this.reload();
    } catch {
      // The card keeps what it has.
    }
  }

  async reload() {
    const chat = this.chat;
    if (!chat) return;
    try {
      const card = await connectorsApi.whatsappCard(chat);
      if (this.chat !== chat) return;
      if (card) this.card = card;
      else this.dismiss();
    } catch {
      // Keep the card as it is.
    }
  }

  dismiss() {
    this.version++;
    this.chat = null;
    this.card = null;
    this.enlarged = null;
    this.notice = "";
    this.sending = false;
  }

  /** Enter or the arrow: the text goes to this chat as typed. While sending the card says so; when that fails it says
   *  why and puts the text back, so nothing typed is lost. */
  async send() {
    const chat = this.chat;
    const text = this.draft.trim();
    if (!chat || !text || this.sending) return;
    this.sending = true;
    this.notice = "Versturen…";
    this.draft = "";
    try {
      const name = await connectorsApi.whatsappReply(chat, text);
      if (this.chat === chat) this.dismiss();
      this.confirm(`Verstuurd naar ${name}`);
    } catch (e) {
      if (this.chat === chat) {
        this.notice = `Niet verstuurd: ${String(e)}`;
        this.draft = text;
      }
    } finally {
      this.sending = false;
    }
  }

  async markRead() {
    if (this.chat) await connectorsApi.whatsappMarkRead(this.chat);
    this.dismiss();
  }

  /** Returns the Nook that answers, or null when that could not start. */
  async askNook(): Promise<string | null> {
    if (!this.chat) return null;
    try {
      const id = await connectorsApi.whatsappAskNook(this.chat);
      this.dismiss();
      return id;
    } catch (e) {
      this.notice = String(e);
      return null;
    }
  }

  async mute() {
    if (this.chat) await connectorsApi.whatsappMute(this.chat);
    this.dismiss();
  }

  async hide() {
    if (this.chat) await connectorsApi.whatsappIgnore(this.chat);
    this.dismiss();
  }

  /** A click on a file: fetched from the gateway if needed and opened with the system's app. The card stays open. */
  async open(message: string, label: string) {
    const chat = this.chat;
    if (!chat) return;
    this.notice = `${label} openen…`;
    try {
      await connectorsApi.whatsappOpenFile(chat, message);
      if (this.chat === chat) this.notice = "";
    } catch (e) {
      if (this.chat === chat) this.notice = String(e);
    }
  }

  /** A short confirmation after the card closed ("Verstuurd naar Lisa"), in the bar's toast. */
  private confirm(text: string) {
    toast.success(text);
  }
}

/** Profile photos of chats (a person's, a group's), fetched a few at a time as the lists ask for them. A chat without
 *  one keeps its initials. */
class AvatarState {
  photos = $state<Record<string, string>>({});
  private asked = new Set<string>();
  private queue = new Set<string>();
  private timer: ReturnType<typeof setTimeout> | null = null;

  /** Asks for a chat's photo unless it is known or was asked for already. */
  want(chat: string) {
    if (!chat || chat in this.photos || this.asked.has(chat)) return;
    this.asked.add(chat);
    this.queue.add(chat);
    this.timer ??= setTimeout(() => this.flush(), 60);
  }

  private async flush() {
    this.timer = null;
    const batch = [...this.queue].slice(0, 30);
    batch.forEach((c) => this.queue.delete(c));
    if (this.queue.size) this.timer = setTimeout(() => this.flush(), 60);
    try {
      const found = await connectorsApi.whatsappAvatars(batch);
      if (Object.keys(found).length) this.photos = { ...this.photos, ...found };
    } catch {
      // Not connected (yet): the chats are asked for again the next time the app starts.
    }
  }
}

export const whatsapp = new WhatsAppCardState();
export const avatars = new AvatarState();
