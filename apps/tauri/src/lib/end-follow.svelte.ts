// One scroll view that follows the end of a conversation by the rules in `end-follow.ts`: attach it to the element
// that scrolls (`{@attach follow.attach}`), whose first child holds the rows. Rows matching `rows` are what the
// reading anchor holds in place while you read back.
import { anchorCorrection, FAR, gap, heldHeight, keyDirection, nearEnd, reaction } from "./end-follow";

type Direction = "up" | "down" | "none";

export class EndFollow {
  /** Whether new content scrolls the view to the end. */
  following = $state(true);
  /** Whether the view is far enough from the end to offer "To the end". */
  far = $state(false);

  #rows: string;
  #holding = false;
  #held = 0;
  #el: HTMLElement | null = null;
  #content: HTMLElement | null = null;
  /** Room under the rows that stands in for what they lost while held, outside what is measured. */
  #spacer: HTMLElement | null = null;
  #anchor: { row: Element; top: number } | null = null;
  #lastTop = 0;
  #dragging = false;
  #touchY: number | null = null;
  #touchDirection: Direction = "none";
  #touchUntil = 0;
  #picking = 0;

  constructor(rows = "[data-row]") {
    this.#rows = rows;
  }

  /** Scrolls to the end and follows it again ("To the end", or a message you sent). */
  toEnd(smooth = false) {
    this.following = true;
    this.far = false;
    const el = this.#el;
    if (!el) return;
    el.scrollTo({ top: el.scrollHeight, behavior: smooth ? "smooth" : "auto" });
    this.#lastTop = el.scrollTop;
  }

  /** Stops following, for a jump of Nook's own into the middle (a search match, "Go to error"). */
  release() {
    this.following = false;
  }

  /** While true (the agent works) the content never gets shorter; false lets it fit its rows again. */
  hold(on: boolean) {
    if (this.#holding === on) return;
    this.#holding = on;
    if (!on) this.unhold();
  }

  /** Lets the held height go, for a change you made yourself (folding a group closed). */
  unhold() {
    this.#held = 0;
    this.#spacer?.remove();
    this.#spacer = null;
  }

  attach = (el: HTMLElement) => {
    this.#el = el;
    // The browser's own anchoring (Chromium) would fight the one below; WebKit has none.
    el.style.overflowAnchor = "none";
    const observer = new ResizeObserver(() => this.#resized());
    const watch = () => {
      const content = [...el.children].find((c) => c !== this.#spacer) as HTMLElement | undefined ?? null;
      if (content === this.#content) return;
      if (this.#content) observer.unobserve(this.#content);
      this.#content = content;
      if (content) observer.observe(content);
    };
    observer.observe(el);
    watch();
    const mutations = new MutationObserver(watch);
    mutations.observe(el, { childList: true });

    const onWheel = (e: WheelEvent) => {
      if (Math.abs(e.deltaY) < Math.abs(e.deltaX) || e.deltaY === 0) return;
      const up = e.deltaY < 0;
      if (this.#innerScrolls(e.target, up)) return;
      this.#input(up ? "up" : "down");
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.defaultPrevented || e.ctrlKey || e.metaKey || e.altKey) return;
      const target = e.target as HTMLElement | null;
      if (target?.closest?.("input, textarea, select, [contenteditable=''], [contenteditable='true']")) return;
      const active = document.activeElement;
      if (active && active !== document.body && !el.contains(active)) return;
      const direction = keyDirection(e.key, e.shiftKey);
      if (direction) this.#input(direction);
    };
    // A press on the scroll view itself, not on a row in it, is a press on its scrollbar.
    const onPointerDown = (e: PointerEvent) => {
      if (e.target === el && e.pointerType !== "touch") this.#dragging = true;
    };
    const onPointerUp = () => {
      if (!this.#dragging) return;
      this.#dragging = false;
      if (nearEnd(el)) this.following = true;
    };
    const onTouchStart = (e: TouchEvent) => {
      this.#touchY = e.touches[0]?.clientY ?? null;
      this.#touchDirection = "none";
    };
    const onTouchMove = (e: TouchEvent) => {
      const y = e.touches[0]?.clientY;
      if (y === undefined || this.#touchY === null) return;
      // A finger moving down pulls the content down: the view goes up.
      if (Math.abs(y - this.#touchY) < 2) return;
      this.#touchDirection = y > this.#touchY ? "up" : "down";
      this.#touchY = y;
      if (this.#touchDirection === "up") this.following = false;
    };
    const onTouchEnd = () => {
      this.#touchY = null;
      // The view still glides after the finger lifts; reaching the end in that glide follows again.
      this.#touchUntil = performance.now() + 1500;
    };
    const onScroll = () => {
      const top = el.scrollTop;
      const moved: Direction = top < this.#lastTop - 0.5 ? "up" : top > this.#lastTop + 0.5 ? "down" : "none";
      this.#lastTop = top;
      if (this.#dragging || this.#touchY !== null) {
        if (moved !== "none") this.following = reaction(this.following, moved, el);
      } else if (performance.now() < this.#touchUntil && this.#touchDirection === "down" && nearEnd(el)) {
        this.following = true;
      }
      this.far = gap(el) > FAR;
      this.#pickAnchorSoon();
    };

    el.addEventListener("wheel", onWheel, { passive: true });
    el.addEventListener("scroll", onScroll, { passive: true });
    el.addEventListener("pointerdown", onPointerDown);
    el.addEventListener("touchstart", onTouchStart, { passive: true });
    el.addEventListener("touchmove", onTouchMove, { passive: true });
    el.addEventListener("touchend", onTouchEnd, { passive: true });
    window.addEventListener("pointerup", onPointerUp);
    window.addEventListener("keydown", onKey);
    return () => {
      observer.disconnect();
      mutations.disconnect();
      el.removeEventListener("wheel", onWheel);
      el.removeEventListener("scroll", onScroll);
      el.removeEventListener("pointerdown", onPointerDown);
      el.removeEventListener("touchstart", onTouchStart);
      el.removeEventListener("touchmove", onTouchMove);
      el.removeEventListener("touchend", onTouchEnd);
      window.removeEventListener("pointerup", onPointerUp);
      window.removeEventListener("keydown", onKey);
      cancelAnimationFrame(this.#picking);
      this.#spacer?.remove();
      this.#spacer = null;
      if (this.#el === el) this.#el = null;
      this.#content = null;
      this.#anchor = null;
    };
  };

  /** A step of your own: up lets go at once, down follows again once the browser moved the view to the end. */
  #input(direction: "up" | "down") {
    if (direction === "up") {
      this.following = false;
      return;
    }
    requestAnimationFrame(() => {
      if (this.#el) this.following = reaction(this.following, direction, this.#el);
    });
  }

  /** Whether a wheel step goes to a scrolling element inside the view (a long code block) rather than the view. */
  #innerScrolls(target: EventTarget | null, up: boolean): boolean {
    let node = target instanceof Element ? target : null;
    while (node && node !== this.#el) {
      if (node instanceof HTMLElement && node.scrollHeight > node.clientHeight + 1) {
        const overflow = getComputedStyle(node).overflowY;
        if (overflow === "auto" || overflow === "scroll") {
          if (up ? node.scrollTop > 0 : node.scrollTop + node.clientHeight < node.scrollHeight - 1) return true;
        }
      }
      node = node.parentElement;
    }
    return false;
  }

  /** The content or the view changed size: follow the end, or keep the row you read where it was. */
  #resized() {
    const el = this.#el;
    const content = this.#content;
    if (!el) return;
    if (content && this.#holding) {
      const natural = content.offsetHeight;
      this.#held = heldHeight(this.#held, natural, true);
      const room = this.#held - natural;
      if (room > 0 && !this.#spacer) {
        this.#spacer = document.createElement("div");
        this.#spacer.setAttribute("aria-hidden", "true");
        this.#spacer.style.flex = "none";
        el.appendChild(this.#spacer);
      }
      if (this.#spacer) this.#spacer.style.height = `${Math.max(0, room)}px`;
    }
    if (this.following) {
      el.scrollTop = el.scrollHeight;
    } else if (this.#anchor?.row.isConnected) {
      const shift = anchorCorrection(this.#anchor.top, this.#top(this.#anchor.row, el));
      if (shift) el.scrollTop += shift;
    }
    this.#lastTop = el.scrollTop;
    this.far = gap(el) > FAR;
    this.#pickAnchor();
  }

  #pickAnchorSoon() {
    if (this.#picking) return;
    this.#picking = requestAnimationFrame(() => {
      this.#picking = 0;
      this.#pickAnchor();
    });
  }

  /** Remembers the first row whose bottom is in view, and where it is. */
  #pickAnchor() {
    const el = this.#el;
    if (!el || this.following) {
      this.#anchor = null;
      return;
    }
    const viewTop = el.getBoundingClientRect().top;
    for (const row of el.querySelectorAll(this.#rows)) {
      const rect = row.getBoundingClientRect();
      if (rect.height > 0 && rect.bottom > viewTop + 1) {
        this.#anchor = { row, top: rect.top - viewTop };
        return;
      }
    }
    this.#anchor = null;
  }

  #top(row: Element, el: HTMLElement): number {
    return row.getBoundingClientRect().top - el.getBoundingClientRect().top;
  }
}
