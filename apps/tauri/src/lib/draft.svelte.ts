// What is typed or attached in the input field but not sent yet. The bar's panel unmounts when it closes, so its draft
// lives here: closing the bar keeps the text, and a file dropped on the closed round Nook waits here for the field.
import { brainApi, fileBase64, type Attachment } from "./brain";

export interface DraftImage {
  mediaType: string;
  base64: string;
  url: string;
}

export class Draft {
  text = $state("");
  images = $state<DraftImage[]>([]);
  attachment = $state<Attachment | null>(null);
  reading = $state(false);
  fileError = $state<string | null>(null);
  // The native file picker takes focus from the bar's window; the bar must not close because of that.
  picking = $state(false);

  /** What a badge on the closed bar counts: files waiting in the field. */
  get files() {
    return this.images.length + (this.attachment || this.reading ? 1 : 0);
  }

  get empty() {
    return !this.text.trim() && !this.attachment && !this.images.length;
  }

  addImage(mediaType: string, base64: string) {
    this.images = [...this.images, { mediaType, base64, url: `data:${mediaType};base64,${base64}` }];
  }

  clear() {
    this.text = "";
    this.images = [];
    this.attachment = null;
  }

  async addFiles(files: FileList | File[]) {
    this.fileError = null;
    for (const file of Array.from(files)) {
      if (file.type.startsWith("image/")) {
        this.addImage(file.type, await fileBase64(file));
        continue;
      }
      this.reading = true;
      try {
        this.attachment = await brainApi.readAttachment(file.name, await fileBase64(file));
      } catch (e) {
        this.fileError = String(e);
      } finally {
        this.reading = false;
      }
    }
  }
}

/** The draft of the bar's compact field; the main window's fields keep their own. */
export const barDraft = new Draft();
