// What is typed or attached in a composer but not sent yet: the text, pictures, and (where the app can read one) a
// document whose text goes with the question. Shared by every web surface of Nook (the Tauri app, the browser
// extension's side panel); each passes in what it can do with a document.

export interface DraftImage {
  mediaType: string;
  base64: string;
  url: string;
}

/** A document read into text, ready to go with the question. */
export interface DraftDocument {
  name: string;
  text: string;
}

/** Reads a document (text, PDF, Word…) into text. A surface without one takes pictures only. */
export type DocumentReader = (name: string, base64: string) => Promise<DraftDocument>;

/** At most this many pictures wait at once; more is a mistake, and each one costs the model tokens. */
export const MAX_IMAGES = 10;

export class Draft {
  text = $state("");
  images = $state<DraftImage[]>([]);
  attachment = $state<DraftDocument | null>(null);
  reading = $state(false);
  fileError = $state<string | null>(null);
  // A native file picker takes focus from a window that closes on blur (the Tauri bar); it must not close for that.
  picking = $state(false);

  constructor(private readonly readDocument: DocumentReader | null = null) {}

  /** Whether documents (not only pictures) can be attached here. */
  get readsDocuments() {
    return this.readDocument !== null;
  }

  /** What a badge counts: files waiting in the field. */
  get files() {
    return this.images.length + (this.attachment || this.reading ? 1 : 0);
  }

  get empty() {
    return !this.text.trim() && !this.attachment && !this.images.length;
  }

  addImage(mediaType: string, base64: string) {
    if (this.images.length >= MAX_IMAGES) return;
    this.images = [...this.images, { mediaType, base64, url: `data:${mediaType};base64,${base64}` }];
  }

  removeImage(index: number) {
    this.images = this.images.filter((_, i) => i !== index);
  }

  clear() {
    this.text = "";
    this.images = [];
    this.attachment = null;
  }

  /** Files chosen, dropped or pasted: pictures join the strip, a document is read when this surface can. */
  async addFiles(files: FileList | File[]) {
    this.fileError = null;
    for (const file of Array.from(files)) {
      if (file.type.startsWith("image/")) {
        this.addImage(file.type, await fileBase64(file));
        continue;
      }
      if (!this.readDocument) continue;
      this.reading = true;
      try {
        this.attachment = await this.readDocument(file.name, await fileBase64(file));
      } catch (e) {
        this.fileError = String(e);
      } finally {
        this.reading = false;
      }
    }
  }
}

/** A file's contents as base64, without the `data:` prefix. */
export function fileBase64(file: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result).split(",")[1] ?? "");
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(file);
  });
}
