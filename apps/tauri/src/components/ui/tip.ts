// The fast tooltip (`.nookTip`), as a Svelte action: `<button use:tip={label}>`. It opens after a 150 ms rest,
// swaps at once to the next control within 400 ms, closes at once on leave, click, scroll or key, and is drawn in one
// element on `document.body`, so no scroll view or narrow column clips it. It is placed and flipped by `placeTip`.
// It also sets `aria-label` when the control has no text of its own, so an icon button is named once.
import { TipClock, placeTip, type TipEdge } from "../../lib/ui-parts";

const clock = new TipClock();
let bubble: HTMLDivElement | null = null;
let owner: HTMLElement | null = null;

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

export function tip(node: HTMLElement, options: TipOptions) {
  let text = typeof options === "object" && options ? options.text : options;
  let edge: TipEdge = (typeof options === "object" && options?.edge) || "bottom";
  let whenCut = typeof options === "object" && !!options?.whenCut;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const label = () => {
    if (text && !node.textContent?.trim() && !node.hasAttribute("aria-label")) node.setAttribute("aria-label", text);
  };
  label();

  const enter = () => {
    if (!text || (whenCut && !isCut(node))) return;
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
        if (text && bubble) bubble.textContent = text;
        else hide();
      }
    },
    destroy() {
      clearTimeout(timer);
      if (owner === node) hide();
      node.removeEventListener("pointerenter", enter);
      node.removeEventListener("pointerleave", leave);
      node.removeEventListener("focus", enter);
      node.removeEventListener("blur", leave);
    },
  };
}
