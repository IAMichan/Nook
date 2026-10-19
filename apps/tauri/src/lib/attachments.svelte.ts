// Afbeeldingen die naar het invoerveld van de balk moeten (een schermdeel). De balk luistert altijd, ook dicht; het
// invoerveld neemt ze zodra het er is.
import { serviceEvents } from "./services";

export interface Attachment {
  mediaType: string;
  base64: string;
}

class Attachments {
  pending = $state<Attachment[]>([]);
  private started = false;

  start() {
    if (this.started) return;
    this.started = true;
    serviceEvents.onAttachImage((img) => (this.pending = [...this.pending, img]));
  }

  take(): Attachment[] {
    const all = this.pending;
    this.pending = [];
    return all;
  }
}

export const attachments = new Attachments();
