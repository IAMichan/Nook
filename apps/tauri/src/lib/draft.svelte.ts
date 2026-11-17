// The Tauri app's drafts: the shared `Draft` (packages/web-ui) with Rust reading dropped documents into text. The bar's
// panel unmounts when it closes, so its draft lives here: closing the bar keeps the text, and a file dropped on the
// closed round Nook waits here for the field.
import { Draft as SharedDraft } from "@nook/web-ui/draft.svelte";
import { brainApi } from "./brain";

export type { DraftImage } from "@nook/web-ui/draft.svelte";

export class Draft extends SharedDraft {
  constructor() {
    super((name, base64) => brainApi.readAttachment(name, base64));
  }

  /** A path dropped on the window or pasted into the field: a picture joins the strip, a file, zip or folder is read. */
  async addPath(path: string) {
    this.fileError = null;
    this.reading = true;
    try {
      const read = await brainApi.readAttachmentPath(path);
      if (read.kind === "image") this.addImage(read.mediaType, read.base64);
      else this.attachment = { name: read.name, text: read.text };
    } finally {
      this.reading = false;
    }
  }
}

/** The draft of the bar's compact field; the main window's fields keep their own. */
export const barDraft = new Draft();
