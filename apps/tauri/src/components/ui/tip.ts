// The fast tooltip (`.nookTip`), as a Svelte action: `<button use:tip={label}>`. It opens after a 150 ms rest,
// swaps at once to the next control within 400 ms, closes at once on leave, click, scroll or key, and is drawn in one
// element on `document.body`, so no scroll view or narrow column clips it. It is placed and flipped by `placeTip`.
// It also sets `aria-label` when the control has no text of its own, so an icon button is named once.
import { TipClock, placeTip, shouldShowTipText, type TipEdge } from "../../lib/ui-parts";

const clock = new TipClock();
let bubble: HTMLDivElement | null = null;
let owner: HTMLElement | null = null;
let delegatedTimer: ReturnType<typeof setTimeout> | undefined;
let delegatedTarget: HTMLElement | null = null;
let tipsInstalled = false;

function bubbleElement(): HTMLDivElement {
  if (bubble) return bubble;
  bubble = document.createElement("div");
  bubble.className = "nook-tip";
  bubble.setAttribute("role", "tooltip");
  document.body.appendChild(bubble);
  const close = () => hide(true);
  window.addEventListener("scroll", close, true);
  window.addEventListener("keydown", close, true);
  window.addEventListener("pointerdown", close, true);
  return bubble;
}

function show(node: HTMLElement, text: string, edge: TipEdge) {
  const el = bubbleElement();
  el.textContent = text;
  el.style.visibility = "hidden";
  el.classList.add("on");
  const r = node.getBoundingClientRect();
  const place = placeTip({ left: r.left, top: r.top, width: r.width, height: r.height },
    { width: el.offsetWidth, height: el.offsetHeight }, { width: window.innerWidth, height: window.innerHeight }, edge);
  el.style.left = `${place.left}px`;
  el.style.top = `${place.top}px`;
  el.style.visibility = "";
  owner = node;
  clock.shown();
}

function hide(dismissed = false) {
  clearTimeout(delegatedTimer);
  delegatedTimer = undefined;
  delegatedTarget = null;
  if (!bubble) return;
  bubble.classList.remove("on");
  owner = null;
  if (dismissed) clock.dismiss();
  else clock.leave(performance.now());
}

/// `whenCut`: only while the text of the element is cut off (a long title ending in "…"), as the Mac's `nookTip` on
/// truncated labels: a name you can read whole needs no tooltip repeating it.
export type TipOptions = string | null | undefined | { text: string | null | undefined; edge?: TipEdge; whenCut?: boolean };

/// True when an element's text runs past its box (ellipsis or clipping).
export function isCut(node: HTMLElement): boolean {
  return node.scrollWidth > node.clientWidth + 1 || node.scrollHeight > node.clientHeight + 1;
}

/// True when the element or any descendant inside it has clipped/truncated text.
export function isNodeOrChildCut(node: HTMLElement): boolean {
  if (isCut(node)) return true;
  for (const child of node.querySelectorAll<HTMLElement>("*")) {
    if (isCut(child)) return true;
  }
  return false;
}

export function shouldShowTip(node: HTMLElement, text: string | null | undefined, whenCut = false): boolean {
  if (!text) return false;
  return shouldShowTipText(text, node.textContent ?? "", isNodeOrChildCut(node), whenCut);
}

export function tip(node: HTMLElement, options: TipOptions) {
  let text = typeof options === "object" && options ? options.text : options;
  let edge: TipEdge = (typeof options === "object" && options?.edge) || "bottom";
  let whenCut = typeof options === "object" && !!options?.whenCut;
  let timer: ReturnType<typeof setTimeout> | undefined;
  node.setAttribute("data-nook-tip-action", "1");
  const label = () => {
    if (text && !node.textContent?.trim() && !node.hasAttribute("aria-label")) node.setAttribute("aria-label", text);
  };
  label();

  const enter = () => {
    if (!text || !shouldShowTip(node, text, whenCut)) return;
    clearTimeout(timer);
    const wait = clock.enter(performance.now());
    timer = setTimeout(() => text && show(node, text, edge), wait);
  };
  const leave = () => {
    clearTimeout(timer);
    if (owner === node) hide();
  };
  node.addEventListener("pointerenter", enter);
  node.addEventListener("pointerleave", leave);
  node.addEventListener("focus", enter);
  node.addEventListener("blur", leave);

  return {
    update(next: TipOptions) {
      text = typeof next === "object" && next ? next.text : next;
      edge = (typeof next === "object" && next?.edge) || "bottom";
      whenCut = typeof next === "object" && !!next?.whenCut;
      label();
      if (owner === node) {
        if (text && bubble && shouldShowTip(node, text, whenCut)) bubble.textContent = text;
        else hide();
      }
    },
    destroy() {
      clearTimeout(timer);
      node.removeAttribute("data-nook-tip-action");
      if (owner === node) hide();
      node.removeEventListener("pointerenter", enter);
      node.removeEventListener("pointerleave", leave);
      node.removeEventListener("focus", enter);
      node.removeEventListener("blur", leave);
    },
  };
}

/**
 * Installs a document-wide interceptor so native `title` attributes render in Nook's `.nook-tip` style (UI-41) and
 * tooltips that merely repeat an element's visible text only appear when that text is cut off.
 */
export function installNookTips(doc: Document = document): () => void {
  if (tipsInstalled && doc === document) return () => {};
  if (doc === document) tipsInstalled = true;

  const findHost = (target: EventTarget | null): HTMLElement | null => {
    if (!(target instanceof Element)) return null;
    const host = target.closest<HTMLElement>("[title], [data-nook-tip]");
    if (!host || host.tagName === "OPTION" || host.hasAttribute("data-nook-tip-action")) return null;
    return host;
  };

  const hoistTitle = (el: HTMLElement): string | null => {
    const raw = el.getAttribute("title");
    if (raw !== null) {
      el.removeAttribute("title");
      const trimmed = raw.trim();
      if (trimmed) {
        el.setAttribute("data-nook-tip", trimmed);
        if (!el.textContent?.trim() && !el.hasAttribute("aria-label")) {
          el.setAttribute("aria-label", trimmed);
        }
      } else {
        el.removeAttribute("data-nook-tip");
      }
    }
    return el.getAttribute("data-nook-tip");
  };

  const onEnter = (e: Event) => {
    const host = findHost(e.target);
    if (!host) return;
    if (host === delegatedTarget) return;
    const text = hoistTitle(host);
    if (!text || !shouldShowTip(host, text, false)) {
      if (owner && owner !== host) hide();
      delegatedTarget = host;
      return;
    }
    clearTimeout(delegatedTimer);
    delegatedTarget = host;
    const wait = clock.enter(performance.now());
    delegatedTimer = setTimeout(() => {
      if (delegatedTarget === host && doc.contains(host)) {
        const current = hoistTitle(host);
        if (current && shouldShowTip(host, current, false)) show(host, current, "bottom");
      }
    }, wait);
  };

  const onLeave = (e: Event) => {
    const host = findHost(e.target);
    if (!host || host !== delegatedTarget) return;
    const related = (e as MouseEvent | FocusEvent).relatedTarget;
    if (related instanceof Node && host.contains(related)) return;
    clearTimeout(delegatedTimer);
    delegatedTarget = null;
    if (owner === host) hide();
  };

  doc.addEventListener("pointerover", onEnter, true);
  doc.addEventListener("pointerout", onLeave, true);
  doc.addEventListener("focusin", onEnter, true);
  doc.addEventListener("focusout", onLeave, true);

  return () => {
    doc.removeEventListener("pointerover", onEnter, true);
    doc.removeEventListener("pointerout", onLeave, true);
    doc.removeEventListener("focusin", onEnter, true);
    doc.removeEventListener("focusout", onLeave, true);
    if (doc === document) tipsInstalled = false;
  };
}
