// Pointing at a spot in a PDF in the side panel (`PickedPdfPoint` + `PdfPointCapture` on the Mac, AG-106).
// Pure TypeScript so tests run without DOM or PDF.js.
import type { ContextRef } from "./context-refs";

export const PDF_POINT_ID_PREFIX = "pdf-";
export const MILLIMETRES_PER_POINT = 25.4 / 72;
export const PDF_POINT_TEXT_LIMIT = 600;
/** Area around the spot shown in the attached picture, in PDF points, and pixel scale. */
export const PDF_PICTURE_WIDTH = 280;
export const PDF_PICTURE_HEIGHT = 180;
export const PDF_PICTURE_SCALE = 2;
/** The iris mark color matching the browser element picker and macOS `PdfPointCapture.markColor`. */
export const PDF_MARK_COLOR = "rgb(124, 108, 240)";

export interface PdfBox {
  minX: number;
  minY: number;
  maxX: number;
  maxY: number;
}

export interface ShownPdfPoint {
  fromLeft: number;
  fromTop: number;
  width: number;
  height: number;
}

/** A spot clicked in a PDF: the page and where on it, measured from every edge so an agent can find it in the source. */
export interface PickedPdfPoint {
  path: string;
  /** 1-based. */
  page: number;
  pageCount: number;
  /** The page as shown (rotation applied), in PDF points (1/72 inch). */
  width: number;
  height: number;
  /** Distance from the page's left and top edge as shown, in points. */
  fromLeft: number;
  fromTop: number;
  /** The same spot in the PDF's own space: origin bottom-left of the media box, rotation not applied. */
  pdfX: number;
  pdfY: number;
  /** Words on the line at the spot, if any (untrusted PDF data). */
  text: string;
}

export interface PdfCropRect {
  /** Left edge in shown-page points (origin top-left). */
  x: number;
  /** Top edge in shown-page points (origin top-left). */
  y: number;
  width: number;
  height: number;
  /** Pixel dimensions at `PDF_PICTURE_SCALE`. */
  pixelWidth: number;
  pixelHeight: number;
  /** The clicked spot's position inside the crop, in points from top-left. */
  spotX: number;
  spotY: number;
}

export interface PdfTextSpan {
  str: string;
  /** Unrotated PDF user-space bounding box of the span (origin bottom-left). */
  x: number;
  y: number;
  width: number;
  height: number;
}

export const isPdfPath = (path: string): boolean => /\.pdf$/i.test(path.trim());

/** Formats a number using POSIX decimals, up to `digits` decimal places, stripping trailing zeros. */
function formatNumber(value: number, digits: number): string {
  const rounded = Number(value.toFixed(digits));
  return Object.is(rounded, -0) ? "0" : String(rounded);
}

/** Last path component across Unix and Windows separators. */
export function pdfFileName(path: string): string {
  return path.replace(/[\\/]+$/, "").split(/[\\/]/).pop() ?? path;
}

/** Distance from the right edge as shown, in points. */
export const pdfFromRight = (point: PickedPdfPoint): number => Math.max(0, point.width - point.fromLeft);

/** Distance from the bottom edge as shown, in points. */
export const pdfFromBottom = (point: PickedPdfPoint): number => Math.max(0, point.height - point.fromTop);

/** Horizontal share of the page width (0..100). */
export const pdfShareLeft = (point: PickedPdfPoint): number => (point.width > 0 ? (point.fromLeft / point.width) * 100 : 0);

/** Vertical share of the page height (0..100). */
export const pdfShareTop = (point: PickedPdfPoint): number => (point.height > 0 ? (point.fromTop / point.height) * 100 : 0);

/** The name of its tile in the composer: file, page and where on it. */
export function pdfPointName(point: PickedPdfPoint): string {
  return `${pdfFileName(point.path)} \u00b7 ${point.page}/${point.pageCount} \u00b7 ${formatNumber(pdfShareLeft(point), 0)}%, ${formatNumber(pdfShareTop(point), 0)}%`;
}

/** The stem of the picture of the spot that travels along with the snippet. */
export function pdfPointImageName(point: PickedPdfPoint): string {
  const file = pdfFileName(point.path);
  const stem = file.replace(/\.[^.]+$/, "") || file;
  return `${stem}-p${point.page}-${Math.round(point.fromLeft)}x${Math.round(point.fromTop)}`;
}

/** The composer tile reference for this spot, keyed by `id`. */
export function pdfPointReference(point: PickedPdfPoint, id: string): ContextRef {
  return { kind: "element", id, label: pdfPointName(point) };
}

/**
 * What the agent reads: the file, the page, and the spot measured from every edge in points, millimetres and as a
 * share of the page, with the text at the spot.
 */
export function pdfPointSnippet(point: PickedPdfPoint): string {
  const width = Math.max(point.width, 0.0001);
  const height = Math.max(point.height, 0.0001);
  const edge = (pts: number, size: number) =>
    `${formatNumber(pts, 1)} pt (${formatNumber(pts * MILLIMETRES_PER_POINT, 1)} mm, ${formatNumber((pts / size) * 100, 1)}%)`;
  const lines = [
    `Point in PDF \`${point.path}\`, page ${point.page} of ${point.pageCount}`,
    `Page size: ${formatNumber(point.width, 1)} \u00d7 ${formatNumber(point.height, 1)} pt (${formatNumber(point.width * MILLIMETRES_PER_POINT, 1)} \u00d7 ${formatNumber(point.height * MILLIMETRES_PER_POINT, 1)} mm)`,
    `From the left: ${edge(point.fromLeft, width)}`,
    `From the right: ${edge(pdfFromRight(point), width)}`,
    `From the top: ${edge(point.fromTop, height)}`,
    `From the bottom: ${edge(pdfFromBottom(point), height)}`,
    `PDF coordinates (origin bottom left, unrotated): x ${formatNumber(point.pdfX, 1)}, y ${formatNumber(point.pdfY, 1)}`,
    `The attached picture \`${pdfPointImageName(point)}\` shows the area around it; the point is the marked crosshair in its middle.`,
  ];
  const words = point.text.trim();
  if (words) lines.push("", "Text at this point:", words.slice(0, PDF_POINT_TEXT_LIMIT));
  return lines.join("\n");
}

/**
 * A spot on a page in the page's own space, as shown: clockwise rotation (0, 90, 180, 270) applied and the crop box
 * origin taken off. Matches `PickedPdfPoint.shown` on macOS.
 */
export function shownPdfPoint(x: number, y: number, box: PdfBox, rotation: number): ShownPdfPoint {
  const width = box.maxX - box.minX;
  const height = box.maxY - box.minY;
  switch (((rotation % 360) + 360) % 360) {
    case 90:
      return { fromLeft: y - box.minY, fromTop: x - box.minX, width: height, height: width };
    case 180:
      return { fromLeft: box.maxX - x, fromTop: y - box.minY, width, height };
    case 270:
      return { fromLeft: box.maxY - y, fromTop: box.maxX - x, width: height, height: width };
    default:
      return { fromLeft: x - box.minX, fromTop: box.maxY - y, width, height };
  }
}

/**
 * Crop rectangle (280 × 180 pt at 2× scale, clamped inside the page) centered on `point` in shown-page top-left coordinates.
 */
export function pdfCropRect(point: PickedPdfPoint): PdfCropRect {
  const width = Math.min(PDF_PICTURE_WIDTH, Math.max(0, point.width));
  const height = Math.min(PDF_PICTURE_HEIGHT, Math.max(0, point.height));
  const x = Math.min(Math.max(0, point.fromLeft - width / 2), Math.max(0, point.width - width));
  const y = Math.min(Math.max(0, point.fromTop - height / 2), Math.max(0, point.height - height));
  return {
    x,
    y,
    width,
    height,
    pixelWidth: Math.round(width * PDF_PICTURE_SCALE),
    pixelHeight: Math.round(height * PDF_PICTURE_SCALE),
    spotX: point.fromLeft - x,
    spotY: point.fromTop - y,
  };
}

/**
 * Extracts text on the line at `(pdfX, pdfY)` (unrotated PDF space), or falls back to spans in the 160 × 32 pt
 * neighborhood around the spot, matching `PdfPointCapture.text(on:at:)`.
 */
export function extractPdfTextAtPoint(spans: PdfTextSpan[], pdfX: number, pdfY: number): string {
  const nonEmpty = spans.filter((s) => s.str.trim().length > 0);
  if (!nonEmpty.length) return "";

  const hitsSpot = (s: PdfTextSpan) => {
    const h = Math.max(s.height, 8);
    const w = Math.max(s.width, 4);
    return pdfX >= s.x - 6 && pdfX <= s.x + w + 6 && pdfY >= s.y - 6 && pdfY <= s.y + h + 6;
  };

  const direct = nonEmpty.find(hitsSpot);
  if (direct) {
    const lineH = Math.max(direct.height, 10);
    const lineSpans = nonEmpty
      .filter((s) => Math.abs(s.y - direct.y) <= lineH * 0.65)
      .sort((a, b) => a.x - b.x);
    const joined = joinSpans(lineSpans);
    if (joined) return joined;
  }

  const near = nonEmpty
    .filter((s) => {
      const h = Math.max(s.height, 8);
      const w = Math.max(s.width, 4);
      const overlapX = s.x + w >= pdfX - 80 && s.x <= pdfX + 80;
      const overlapY = s.y + h >= pdfY - 16 && s.y <= pdfY + 16;
      return overlapX && overlapY;
    })
    .sort((a, b) => (Math.abs(b.y - a.y) > 4 ? b.y - a.y : a.x - b.x));
  return joinSpans(near);
}

function joinSpans(spans: PdfTextSpan[]): string {
  let out = "";
  let prev: PdfTextSpan | null = null;
  for (const s of spans) {
    if (prev) {
      const sameLine = Math.abs(s.y - prev.y) <= Math.max(prev.height, 10) * 0.65;
      if (!sameLine) out += "\n";
      else if (s.x - (prev.x + prev.width) > 1.5 && !out.endsWith(" ") && !s.str.startsWith(" ")) out += " ";
    }
    out += s.str;
    prev = s;
  }
  return out.trim();
}

/** Draws the macOS-matching white-halo + iris crosshair ring at `(spotX, spotY)` (in points, scaled by `scale`). */
export function drawPdfCrosshair(ctx: CanvasRenderingContext2D, spotX: number, spotY: number, scale = PDF_PICTURE_SCALE): void {
  const radius = 9;
  const arm = 16;
  ctx.save();
  ctx.scale(scale, scale);
  const strokes: [string, number][] = [
    ["rgba(255, 255, 255, 0.9)", 4],
    [PDF_MARK_COLOR, 1.75],
  ];
  for (const [color, width] of strokes) {
    ctx.strokeStyle = color;
    ctx.lineWidth = width;
    ctx.beginPath();
    ctx.arc(spotX, spotY, radius, 0, Math.PI * 2);
    ctx.moveTo(spotX - arm, spotY);
    ctx.lineTo(spotX + arm, spotY);
    ctx.moveTo(spotX, spotY - arm);
    ctx.lineTo(spotX, spotY + arm);
    ctx.stroke();
  }
  ctx.restore();
}
