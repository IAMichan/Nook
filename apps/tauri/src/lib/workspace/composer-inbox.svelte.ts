// Items waiting for a session's composer (`ComposerInbox` on the Mac): the side panel's Explain, Ask, Fix, browser
// picks, and PDF spots put text blocks, snippet tiles, and pictures here, and the session's composer takes them in.
import type { ContextRef } from "./context-refs";
import {
  PDF_POINT_ID_PREFIX,
  pdfPointName,
  pdfPointReference,
  pdfPointSnippet,
  type PickedPdfPoint,
} from "./pdf-point";
import { toast } from "../toast.svelte";
import { tr } from "../i18n.svelte";

export interface ComposerSnippet {
  ref: ContextRef;
  content: string;
}

export interface ComposerDelivery {
  texts: string[];
  snippets: ComposerSnippet[];
  pictures: string[];
}

const empty = (): ComposerDelivery => ({ texts: [], snippets: [], pictures: [] });

function makeId(prefix: string): string {
  const rand = typeof crypto !== "undefined" && typeof crypto.randomUUID === "function"
    ? crypto.randomUUID().replace(/-/g, "").slice(0, 8)
    : Math.random().toString(16).slice(2, 10);
  return `${prefix}${rand}`;
}

class ComposerInbox {
  waiting = $state<Record<string, ComposerDelivery>>({});

  private key(session: string): string {
    return session.replace(/^run:/, "");
  }

  add(text: string, session: string) {
    const key = this.key(session);
    const cur = this.waiting[key] ?? empty();
    this.waiting[key] = { ...cur, texts: [...cur.texts, text] };
  }

  /** A spot clicked in a PDF beside the session, as a snippet tile with a picture of the area around it. */
  addPdfPoint(point: PickedPdfPoint, imagePath: string | null, session: string) {
    const key = this.key(session);
    const id = makeId(PDF_POINT_ID_PREFIX);
    const snippet: ComposerSnippet = {
      ref: pdfPointReference(point, id),
      content: pdfPointSnippet(point),
    };
    const cur = this.waiting[key] ?? empty();
    this.waiting[key] = {
      texts: cur.texts,
      snippets: [...cur.snippets, snippet],
      pictures: imagePath ? [...cur.pictures, imagePath] : cur.pictures,
    };
    toast.success(tr("{name} toegevoegd aan je bericht", "Added {name} to your message", { name: pdfPointName(point) }));
  }

  /** Whether anything is waiting for a session. */
  has(session: string): boolean {
    const cur = this.waiting[this.key(session)];
    return !!cur && (cur.texts.length > 0 || cur.snippets.length > 0 || cur.pictures.length > 0);
  }

  /** The text blocks for a session, taken out of the inbox (kept for callers expecting strings only). */
  take(session: string): string[] {
    return this.takeDelivery(session).texts;
  }

  /** All pending text blocks, snippet tiles, and pictures for a session, taken out of the inbox. */
  takeDelivery(session: string): ComposerDelivery {
    const key = this.key(session);
    const cur = this.waiting[key];
    if (!cur) return empty();
    delete this.waiting[key];
    return cur;
  }
}

export const composerInbox = new ComposerInbox();
