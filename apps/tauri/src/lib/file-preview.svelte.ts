// The file preview (the Mac's `FilePreviewWindow`): `previewFile(path)` from anywhere shows a photo, PDF, video or
// sound file over the window (`components/FilePreview.svelte`, mounted once per window in App.svelte), with
// "Open in app". A view that cannot import this can send `window.dispatchEvent(new CustomEvent("nook-preview-file",
// { detail: path }))`.
export const PREVIEW_EVENT = "nook-preview-file";

class Preview {
  path = $state<string | null>(null);
  open(path: string) { this.path = path; }
  close() { this.path = null; }
}

export const preview = new Preview();
export const previewFile = (path: string) => preview.open(path);

/// Whether Nook shows a file itself, by its name; other files go straight to their app.
export function previewable(name: string): boolean {
  return /\.(png|jpe?g|gif|webp|bmp|svg|pdf|mp4|m4v|webm|mov|mp3|m4a|wav|ogg|opus)$/i.test(name);
}
