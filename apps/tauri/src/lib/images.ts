// Pictures with a message, as the iPhone sends them (`CompanionImage`): JPEGs made small enough on the phone, at most two.
export const MAX_IMAGES = 2;
export const MAX_IMAGE_BYTES = 90 * 1024;

/** A picked picture as a JPEG under the limit (base64, without the data: prefix), or null when it cannot be made so. */
export async function shrinkToJpeg(file: Blob): Promise<string | null> {
  const bitmap = await createImageBitmap(file).catch(() => loadImage(file));
  if (!bitmap) return null;
  for (const side of [1600, 1200, 900, 700, 500]) {
    const scale = Math.min(1, side / Math.max(bitmap.width, bitmap.height));
    const canvas = document.createElement("canvas");
    canvas.width = Math.round(bitmap.width * scale);
    canvas.height = Math.round(bitmap.height * scale);
    canvas.getContext("2d")?.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
    for (const quality of [0.8, 0.65, 0.5]) {
      const url = canvas.toDataURL("image/jpeg", quality);
      const base64 = url.slice(url.indexOf(",") + 1);
      if (base64Bytes(base64) <= MAX_IMAGE_BYTES) return base64;
    }
  }
  return null;
}

/** How many bytes a base64 text decodes to. */
export function base64Bytes(base64: string): number {
  const padding = base64.endsWith("==") ? 2 : base64.endsWith("=") ? 1 : 0;
  return Math.floor((base64.length * 3) / 4) - padding;
}

/** The picture through an <img>, for a WebView whose createImageBitmap cannot read it (HEIC on some phones). */
function loadImage(file: Blob): Promise<HTMLImageElement | null> {
  return new Promise((resolve) => {
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => { URL.revokeObjectURL(url); resolve(img); };
    img.onerror = () => { URL.revokeObjectURL(url); resolve(null); };
    img.src = url;
  });
}
