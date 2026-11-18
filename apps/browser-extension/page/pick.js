// Pointing at something on a page for your coding agent, the same gesture as in Nook's own browser and PDF viewer
// (BrowserPickScript and PdfPointCapture in apps/macos): the element under the pointer gets an outline with a badge
// that names it (`h2.mkt-title`), and a click takes it. In a PDF, which the browser draws in its own viewer, a click
// takes the spot instead. The service worker then turns what was taken into text (lib/core.js) and hands it back to
// `copy`, which puts it on the clipboard, so pasting it in an agent's prompt says exactly where to change something.
//
// Injected into the page's isolated world only when the user asks (the side panel's button or the keyboard shortcut);
// the service worker calls `__nookPick.element()`, `.point()`, `.cancel()` and `.copy(text, image, name)`. Clicks
// while selecting never reach the page. Its strip and toast live in a closed shadow root, so the page's styles cannot
// hide or restyle them; the outlines sit in a layer of their own that never takes a click.
(() => {
  if (globalThis.__nookPick) return;

  const say = (key, ...subs) => {
    try {
      return chrome.i18n.getMessage(key, subs) || '';
    } catch {
      return '';
    }
  };

  /** The iris Nook marks what you selected with, in its browser and in PDFs alike. */
  const IRIS = '#7c6cf0';
  /** As much visible text and markup as an element brings along (BrowserPickScript.textLimit and .htmlLimit). */
  const TEXT_LIMIT = 1500;
  const HTML_LIMIT = 6000;
  const LAYER = '__nook-pick-layer';

  let finish = null;

  // MARK: - The strip (what to do now) and the toast (what was copied)

  const ui = { host: null, strip: null, label: null, toast: null, timer: null };

  function build() {
    if (ui.host?.isConnected) return;
    const host = document.createElement('nook-pick');
    host.style.cssText = 'all:initial;position:fixed;inset:0;z-index:2147483647;pointer-events:none';
    const root = host.attachShadow({ mode: 'closed' });
    root.innerHTML = `
      <style>
        :host { all: initial; }
        .note { position: fixed; left: 50%; transform: translate(-50%, 8px); opacity: 0; max-width: calc(100vw - 32px);
                transition: opacity .2s ease-out, transform .2s ease-out; display: flex; align-items: center; gap: 8px;
                padding: 7px 14px; border-radius: 12px; background: rgba(23,23,23,.94); border: 1px solid #262626;
                color: #f5f5f5; font: 500 13px/1.3 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif;
                box-shadow: 0 8px 28px rgba(0,0,0,.32); backdrop-filter: blur(12px); }
        .strip { top: 14px; }
        .toast { bottom: 18px; }
        .dot { flex: none; width: 7px; height: 7px; border-radius: 50%; background: ${IRIS}; }
        .label { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .on { opacity: 1; transform: translate(-50%, 0); }
        @media (prefers-reduced-motion: reduce) { .note { transition: none; } }
      </style>
      <div class="note strip" role="status"><span class="dot"></span><span class="label"></span></div>
      <div class="note toast" role="status"><span class="dot"></span><span class="label"></span></div>`;
    ui.strip = root.querySelector('.strip');
    ui.label = ui.strip.querySelector('.label');
    ui.toast = root.querySelector('.toast');
    ui.host = host;
    document.documentElement.appendChild(host);
  }

  function showStrip(text) {
    build();
    ui.label.textContent = text;
    ui.strip.classList.add('on');
  }

  function hideStrip() {
    ui.strip?.classList.remove('on');
  }

  function toast(text) {
    build();
    ui.toast.querySelector('.label').textContent = text;
    ui.toast.classList.add('on');
    clearTimeout(ui.timer);
    ui.timer = setTimeout(() => {
      ui.toast.classList.remove('on');
      // The marks of what was taken go with the toast: the page is the user's again.
      setTimeout(() => document.getElementById(LAYER)?.remove(), 250);
    }, 2600);
  }

  // MARK: - Outlines

  function layer() {
    let root = document.getElementById(LAYER);
    if (!root) {
      root = document.createElement('div');
      root.id = LAYER;
      root.style.cssText = 'position:absolute;left:0;top:0;width:0;height:0;z-index:2147483646;pointer-events:none';
      document.documentElement.appendChild(root);
    }
    return root;
  }

  /** The tag with its id, or with its first two classes: `button#buy`, `h2.mkt-title`. */
  function name(element) {
    const tag = element.tagName.toLowerCase();
    if (element.id) return tag + '#' + element.id;
    const classes = typeof element.className === 'string'
      ? element.className.trim().split(/\s+/).filter((c) => c && !c.startsWith('__nook')).slice(0, 2) : [];
    return classes.length ? tag + '.' + classes.join('.') : tag;
  }

  function frame(filled) {
    const box = document.createElement('div');
    box.style.cssText = `position:absolute;box-sizing:border-box;border:1.5px solid ${IRIS};border-radius:3px;` +
      `background:${filled ? 'rgba(124,108,240,.14)' : 'rgba(124,108,240,.06)'};display:none`;
    const badge = document.createElement('div');
    badge.style.cssText = `position:absolute;left:-1.5px;bottom:100%;margin-bottom:3px;padding:1px 6px;border-radius:4px;` +
      `background:${IRIS};color:#fff;font:600 11px/16px -apple-system,system-ui,sans-serif;white-space:nowrap;` +
      'max-width:320px;overflow:hidden;text-overflow:ellipsis';
    box.appendChild(badge);
    layer().appendChild(box);
    return { box, badge };
  }

  function place(shown, element) {
    const r = element.getBoundingClientRect();
    shown.box.style.display = 'block';
    shown.box.style.left = (r.left + window.scrollX) + 'px';
    shown.box.style.top = (r.top + window.scrollY) + 'px';
    shown.box.style.width = r.width + 'px';
    shown.box.style.height = r.height + 'px';
    shown.badge.textContent = name(element);
    // No room above the element: the badge goes inside its top edge.
    const inside = r.top < 22;
    shown.badge.style.bottom = inside ? 'auto' : '100%';
    shown.badge.style.top = inside ? '2px' : 'auto';
    shown.badge.style.left = inside ? '2px' : '-1.5px';
  }

  /** A CSS selector that finds the element again: its id, or the path of tags up to five steps or an id. */
  function selector(element) {
    if (element.id) return '#' + CSS.escape(element.id);
    const parts = [];
    for (let node = element; node && node.nodeType === 1 && node !== document.body && parts.length < 5; node = node.parentElement) {
      if (node.id) {
        parts.unshift('#' + CSS.escape(node.id));
        break;
      }
      const same = node.parentElement ? [...node.parentElement.children].filter((c) => c.tagName === node.tagName) : [];
      const tag = node.tagName.toLowerCase();
      parts.unshift(same.length > 1 ? `${tag}:nth-of-type(${same.indexOf(node) + 1})` : tag);
    }
    return parts.length ? parts.join(' > ') : element.tagName.toLowerCase();
  }

  /** The element under a point, also inside open shadow roots. */
  function under(x, y) {
    let found = document.elementFromPoint(x, y);
    while (found?.shadowRoot) {
      const inner = found.shadowRoot.elementFromPoint(x, y);
      if (!inner || inner === found) break;
      found = inner;
    }
    return found;
  }

  function taken(element) {
    const text = (element.innerText || element.getAttribute('aria-label') || element.getAttribute('alt') || '').trim();
    let html = element.outerHTML || '';
    if (html.length > HTML_LIMIT) html = html.slice(0, HTML_LIMIT) + '\n<!-- … clipped -->';
    return { selector: selector(element), label: name(element), text: text.slice(0, TEXT_LIMIT), html };
  }

  // MARK: - Listening while selecting

  const SWALLOWED = ['mousedown', 'mouseup', 'pointerdown', 'pointerup', 'dblclick', 'contextmenu', 'auxclick'];

  function stop(event) {
    event.preventDefault();
    event.stopPropagation();
    event.stopImmediatePropagation();
  }

  /** Listens until `done` is called; returns the function that ends it and resolves the promise. */
  function listen(handlers, resolve) {
    const previousCursor = document.documentElement.style.cursor;
    document.documentElement.style.cursor = 'crosshair';
    for (const [name, handler] of Object.entries(handlers)) window.addEventListener(name, handler, true);
    for (const name of SWALLOWED) window.addEventListener(name, stop, true);
    const done = (value) => {
      for (const [name, handler] of Object.entries(handlers)) window.removeEventListener(name, handler, true);
      for (const name of SWALLOWED) window.removeEventListener(name, stop, true);
      document.documentElement.style.cursor = previousCursor;
      hideStrip();
      finish = null;
      resolve(value);
    };
    finish = done;
    return done;
  }

  /**
   * Selects elements: a click takes the one under the pointer; Shift-click takes it and goes on, for several at once;
   * Return ends with what was taken; Escape stops without anything. Resolves with the elements (none when stopped).
   */
  function element() {
    finish?.([]);
    document.getElementById(LAYER)?.remove();
    return new Promise((resolve) => {
      const hover = frame(true);
      const picked = [];
      let current = null;
      showStrip(say('pickElementHint') || 'Click an element to copy it for your agent · Shift-click for more · Esc stops');
      const end = (value) => {
        hover.box.remove();
        done(value);
      };
      const done = listen({
        mousemove: (event) => {
          const found = under(event.clientX, event.clientY);
          if (!found || found === document.documentElement || found.closest?.('#' + LAYER) || found.tagName === 'NOOK-PICK') return;
          current = found;
          place(hover, current);
        },
        click: (event) => {
          stop(event);
          if (!current) return;
          const mark = frame(false);
          place(mark, current);
          picked.push(taken(current));
          if (!event.shiftKey) end(picked);
          else showStrip(say('pickElementMore', String(picked.length)) || `${picked.length} selected · Shift-click for more · Return copies`);
        },
        keydown: (event) => {
          if (event.key === 'Escape') {
            stop(event);
            document.getElementById(LAYER)?.remove();
            end([]);
          } else if (event.key === 'Enter' && picked.length) {
            stop(event);
            end(picked);
          }
        }
      }, resolve);
    });
  }

  /**
   * Selects a spot in a PDF: the browser draws it in its own viewer, which no page script reaches, so a sheet over it
   * takes the click. Resolves with where it was in the window (CSS pixels) once the sheet is gone again, so a picture
   * of the window taken right after shows the PDF itself; null when stopped.
   */
  function point() {
    finish?.(null);
    return new Promise((resolve) => {
      build();
      const sheet = document.createElement('div');
      sheet.style.cssText = 'position:fixed;inset:0;z-index:2147483645;cursor:crosshair;background:transparent';
      document.documentElement.appendChild(sheet);
      showStrip(say('pickPointHint') || 'Click a spot in the PDF to copy it for your agent · Esc stops');
      const done = listen({
        click: (event) => {
          stop(event);
          const spot = { x: event.clientX, y: event.clientY, width: window.innerWidth, height: window.innerHeight };
          sheet.remove();
          // The strip goes at once (not faded out), and two frames pass, so neither is in the picture taken next.
          ui.host?.remove();
          requestAnimationFrame(() => requestAnimationFrame(() => done(spot)));
        },
        keydown: (event) => {
          if (event.key !== 'Escape') return;
          stop(event);
          sheet.remove();
          done(null);
        }
      }, resolve);
    });
  }

  function cancel() {
    document.getElementById(LAYER)?.remove();
    finish?.(null);
  }

  /**
   * Puts the text (and, for a PDF spot, the picture as a PNG data URL) on the clipboard and says so. The click that
   * took it is a few moments old, so the page may still write the clipboard; when the browser refuses, an old-style
   * copy of the text is tried. Resolves with whether it worked.
   */
  async function copy(text, image, label) {
    let ok = false;
    try {
      if (image && globalThis.ClipboardItem) {
        // Decoded here rather than fetched: the page's own rules may forbid fetching a data URL.
        const bytes = Uint8Array.from(atob(image.slice(image.indexOf(',') + 1)), (c) => c.charCodeAt(0));
        const picture = new Blob([bytes], { type: 'image/png' });
        await navigator.clipboard.write([new ClipboardItem({
          'text/plain': new Blob([text], { type: 'text/plain' }),
          'image/png': picture
        })]);
      } else {
        await navigator.clipboard.writeText(text);
      }
      ok = true;
    } catch {
      ok = copyByCommand(text);
    }
    toast(ok ? (say('pickCopied', label) || `Copied ${label}: paste it in your agent's prompt`) : (say('pickNotCopied') || 'The browser did not allow copying'));
    return ok;
  }

  function copyByCommand(text) {
    const field = document.createElement('textarea');
    field.value = text;
    field.setAttribute('readonly', '');
    field.style.cssText = 'position:fixed;left:-9999px;top:0;opacity:0';
    document.documentElement.appendChild(field);
    field.select();
    let ok = false;
    try {
      ok = document.execCommand('copy');
    } catch {
      ok = false;
    }
    field.remove();
    return ok;
  }

  /** The browser shows this document as a PDF in its own viewer. */
  function isPdf() {
    return document.contentType === 'application/pdf' || !!document.querySelector('body > embed[type="application/pdf"]');
  }

  globalThis.__nookPick = {
    element, point, cancel, copy, isPdf,
    busy: () => !!finish
  };
})();
