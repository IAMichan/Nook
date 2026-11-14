// Nook's hands on a web page. The service worker injects this file into the page's isolated world (the page's own
// scripts cannot see or change it) and then calls `globalThis.__nookAgent[method](params)`. Every method returns a
// plain object: `{ ok: true, text, … }` or `{ ok: false, error }`. Nothing here sends anything anywhere: the result goes
// back to the service worker, and from there to Nook on this Mac.
//
// Refs ("e7") point at elements through a WeakMap, never through attributes on the page, so the page cannot read or
// forge them. A ref stays the same for the same element across snapshots.
//
// While Nook acts, a cursor in Nook's color moves to what it clicks, types in or scrolls, with a badge under it that says
// what it does ("Clicking · Send"), so the user can follow along. It is drawn in a closed shadow root and never takes a
// click itself.
(() => {
  if (globalThis.__nookAgent) return;

  const TEXT_LIMIT = 24_000;
  const INTERACTIVE = [
    'a[href]', 'button', 'input', 'textarea', 'select', 'summary', '[role=button]', '[role=link]', '[role=tab]',
    '[role=menuitem]', '[role=menuitemcheckbox]', '[role=menuitemradio]', '[role=checkbox]', '[role=radio]',
    '[role=switch]', '[role=option]', '[role=combobox]', '[role=textbox]', '[role=searchbox]', '[role=slider]',
    '[contenteditable=""]', '[contenteditable=true]', '[onclick]'
  ].join(',');
  const HEADINGS = 'h1,h2,h3';

  const refOf = new WeakMap();
  const elementOf = new Map();
  let nextRef = 0;

  const clean = (text) => String(text ?? '').replace(/\s+/g, ' ').trim();
  const clip = (text, limit) => (text.length > limit ? text.slice(0, limit - 1) + '…' : text);
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  // A tab in the background draws no frames and Chrome slows its timers: there Nook acts at once, without the glide
  // nobody sees, so it goes on at full speed while the user is in another tab.
  const frame = () => (document.hidden ? Promise.resolve()
    : new Promise((resolve) => { requestAnimationFrame(() => resolve()); setTimeout(resolve, 50); }));
  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const still = () => reduced || document.hidden;
  const say = (key, sub) => {
    try {
      return chrome.i18n.getMessage(key, sub === undefined ? undefined : [String(sub)]) || '';
    } catch {
      return '';
    }
  };

  /** Every element matching `selector`, also inside open shadow roots (web components such as many sites build with). */
  function deepAll(selector, root = document) {
    const found = Array.from(root.querySelectorAll(selector));
    for (const host of root.querySelectorAll('*')) {
      if (host.shadowRoot) found.push(...deepAll(selector, host.shadowRoot));
    }
    return found;
  }

  /** The element the user would hit at a point, also inside open shadow roots. */
  function elementAt(x, y) {
    let element = document.elementFromPoint(x, y);
    while (element?.shadowRoot) {
      const inner = element.shadowRoot.elementFromPoint(x, y);
      if (!inner || inner === element) break;
      element = inner;
    }
    return element;
  }

  // MARK: - The cursor the user sees

  const cursor = { host: null, wrap: null, badge: null, ring: null, x: null, y: null, timer: null };

  function ensureCursor() {
    if (cursor.host?.isConnected) return;
    const host = document.createElement('nook-cursor');
    host.style.cssText = 'all:initial;position:fixed;inset:0;z-index:2147483647;pointer-events:none';
    const root = host.attachShadow({ mode: 'closed' });
    root.innerHTML = `
      <style>
        :host { all: initial; }
        .cursor { position: fixed; left: 0; top: 0; opacity: 0; transition: opacity .2s ease-out; will-change: transform; }
        .cursor.on { opacity: 1; }
        svg { display: block; filter: drop-shadow(0 2px 4px rgba(0,0,0,.35)); transform-origin: 2px 2px; transition: transform .12s ease-out; }
        .press svg { transform: scale(.82); }
        .badge { position: absolute; left: 16px; top: 24px; display: flex; align-items: center; gap: 6px; max-width: 260px;
                 padding: 4px 10px 4px 8px; border-radius: 999px; background: rgba(22,22,28,.92); color: #f3f2f8;
                 font: 600 12px/1.25 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; white-space: nowrap;
                 box-shadow: 0 4px 14px rgba(0,0,0,.28); }
        .badge span { overflow: hidden; text-overflow: ellipsis; }
        .badge i { flex: none; width: 7px; height: 7px; border-radius: 50%; background: #7c6cf0; }
        .ring { position: fixed; left: 0; top: 0; width: 28px; height: 28px; margin: -14px 0 0 -14px; border-radius: 50%;
                border: 2px solid #7c6cf0; background: rgba(124,108,240,.22); opacity: 0; }
        .ring.go { animation: ripple .55s ease-out; }
        @keyframes ripple { from { opacity: 1; transform: var(--at) scale(.4); } to { opacity: 0; transform: var(--at) scale(1.9); } }
        @media (prefers-reduced-motion: reduce) { .cursor, svg { transition: none; } .ring.go { animation-duration: .01s; } }
      </style>
      <div class="ring"></div>
      <div class="cursor">
        <svg width="22" height="24" viewBox="0 0 22 24" aria-hidden="true">
          <path d="M2 1.5 L2 19.5 L6.8 15 L10.3 22.6 L13.6 21.1 L10.2 13.6 L16.8 13.6 Z" fill="#7c6cf0" stroke="#fff" stroke-width="1.6" stroke-linejoin="round"/>
        </svg>
        <div class="badge" role="status"><i></i><span></span></div>
      </div>`;
    cursor.wrap = root.querySelector('.cursor');
    cursor.badge = root.querySelector('.badge span');
    cursor.ring = root.querySelector('.ring');
    cursor.host = host;
    document.documentElement.appendChild(host);
  }

  /**
   * Moves the cursor to a point in the viewport and shows what Nook does there. Quick: a short, eased glide (none when
   * the user asked for reduced motion), so watching Nook never makes it slow. `from`: where it was on the previous page.
   */
  async function moveTo(x, y, label, from) {
    ensureCursor();
    x = Math.max(4, Math.min(innerWidth - 4, x));
    y = Math.max(4, Math.min(innerHeight - 4, y));
    if (cursor.x === null) {
      const start = from && Number.isFinite(from.x) ? from : { x: innerWidth / 2, y: innerHeight - 70 };
      cursor.x = Math.max(4, Math.min(innerWidth - 4, start.x));
      cursor.y = Math.max(4, Math.min(innerHeight - 4, start.y));
      cursor.wrap.style.transition = 'opacity .2s ease-out';
      cursor.wrap.style.transform = `translate(${cursor.x}px, ${cursor.y}px)`;
      await frame();
    }
    cursor.badge.textContent = label;
    cursor.wrap.classList.add('on');
    const distance = Math.hypot(x - cursor.x, y - cursor.y);
    const duration = still() ? 0 : Math.round(Math.max(140, Math.min(460, 120 + distance * 0.35)));
    cursor.wrap.style.transition = `opacity .2s ease-out, transform ${duration}ms cubic-bezier(.22,.8,.24,1)`;
    cursor.wrap.style.transform = `translate(${x}px, ${y}px)`;
    cursor.x = x;
    cursor.y = y;
    clearTimeout(cursor.timer);
    cursor.timer = setTimeout(() => cursor.wrap?.classList.remove('on'), 3500);
    if (duration) await sleep(duration);
  }

  /** A press and a ripple where the cursor is: the click the user sees. */
  function pulse() {
    if (!cursor.wrap) return;
    cursor.wrap.classList.add('press');
    setTimeout(() => cursor.wrap?.classList.remove('press'), 140);
    const ring = cursor.ring;
    ring.style.setProperty('--at', `translate(${cursor.x}px, ${cursor.y}px)`);
    ring.style.transform = `translate(${cursor.x}px, ${cursor.y}px)`;
    ring.classList.remove('go');
    void ring.offsetWidth;
    ring.classList.add('go');
  }

  /** The middle of an element, where the cursor goes and a click lands. */
  function centerOf(element) {
    const box = element.getBoundingClientRect();
    return { x: box.left + Math.min(box.width / 2, Math.max(8, box.width - 8)), y: box.top + box.height / 2 };
  }

  /** Brings an element into view when it is not, before the cursor goes there. */
  async function reveal(element) {
    const box = element.getBoundingClientRect();
    if (box.top >= 0 && box.bottom <= innerHeight && box.left >= 0 && box.right <= innerWidth) return;
    element.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'instant' });
    await frame();
  }

  const short = (element) => clip(nameOf(element) || roleOf(element), 32);
  const where = () => ({ x: cursor.x, y: cursor.y });

  function refFor(element) {
    let ref = refOf.get(element);
    if (!ref) {
      nextRef += 1;
      ref = 'e' + nextRef;
      refOf.set(element, ref);
    }
    elementOf.set(ref, new WeakRef(element));
    return ref;
  }

  /** Whether the user can see the element. `checkVisibility` asks the browser's own layout, much faster than styles. */
  function shown(element) {
    if (!element.isConnected) return false;
    if (element.checkVisibility) {
      return element.checkVisibility({ opacityProperty: true, visibilityProperty: true }) && element.getClientRects().length > 0;
    }
    if (element.getClientRects().length === 0) return false;
    const style = getComputedStyle(element);
    return style.visibility !== 'hidden' && style.display !== 'none' && Number(style.opacity) !== 0;
  }

  function inView(element) {
    const box = element.getBoundingClientRect();
    return box.bottom > 0 && box.right > 0 && box.top < innerHeight && box.left < innerWidth;
  }

  /** What a screen reader would call the element: its label first, then its text. */
  function nameOf(element) {
    const labelledBy = element.getAttribute('aria-labelledby');
    if (labelledBy) {
      const text = labelledBy.split(/\s+/).map((id) => document.getElementById(id)?.innerText || '').join(' ');
      if (clean(text)) return clean(text);
    }
    const aria = element.getAttribute('aria-label');
    if (clean(aria)) return clean(aria);
    if (element.labels && element.labels.length) {
      const text = Array.from(element.labels).map((label) => label.innerText).join(' ');
      if (clean(text)) return clean(text);
    }
    const tag = element.tagName.toLowerCase();
    if (tag === 'input' && ['button', 'submit', 'reset'].includes(element.type)) return clean(element.value);
    if (tag === 'img') return clean(element.alt);
    const text = clean(element.innerText || element.textContent);
    if (text) return text;
    return clean(element.getAttribute('title') || element.getAttribute('placeholder') || element.querySelector?.('img[alt]')?.alt);
  }

  function roleOf(element) {
    const role = element.getAttribute('role');
    if (role) return role;
    const tag = element.tagName.toLowerCase();
    if (tag === 'a') return 'link';
    if (tag === 'input') {
      const type = (element.type || 'text').toLowerCase();
      if (['button', 'submit', 'reset'].includes(type)) return 'button';
      return type === 'text' ? 'textbox' : type;
    }
    if (tag === 'textarea') return 'textbox';
    if (tag === 'select') return 'combobox';
    if (element.isContentEditable) return 'textbox';
    return tag;
  }

  /** A field whose value Nook never reads or types: a password, or a code to sign in with. */
  function secret(field) {
    return field.type === 'password' || /one-time-code/i.test(field.autocomplete || field.getAttribute?.('autocomplete') || '')
      || /otp/i.test(field.name || '') || /otp/i.test(field.id || '');
  }

  /** One line for an element in a snapshot. Passwords never show their value. */
  function line(element, ref) {
    const parts = [`[${ref}] ${roleOf(element)}`];
    const name = clip(nameOf(element), 100);
    if (name) parts.push(JSON.stringify(name));
    const tag = element.tagName.toLowerCase();
    if (tag === 'input' || tag === 'textarea' || tag === 'select') {
      if (element.placeholder && !name.includes(element.placeholder)) parts.push('placeholder=' + JSON.stringify(clip(element.placeholder, 60)));
      if (secret(element)) {
        if (element.value) parts.push('value=(hidden)');
      } else if (element.type === 'checkbox' || element.type === 'radio') {
        parts.push(element.checked ? 'checked' : 'unchecked');
      } else if (tag === 'select') {
        const chosen = element.selectedOptions?.[0];
        if (chosen) parts.push('value=' + JSON.stringify(clip(clean(chosen.text), 60)));
        const options = Array.from(element.options).slice(0, 12).map((o) => clip(clean(o.text), 30));
        if (options.length) parts.push('options=' + JSON.stringify(options));
      } else if (element.value) {
        parts.push('value=' + JSON.stringify(clip(String(element.value), 80)));
      }
      if (element.required) parts.push('required');
    }
    const checked = element.getAttribute('aria-checked') || element.getAttribute('aria-pressed') || element.getAttribute('aria-selected');
    if (checked === 'true') parts.push('on');
    if (element.getAttribute('aria-expanded')) parts.push(element.getAttribute('aria-expanded') === 'true' ? 'expanded' : 'collapsed');
    if (element.disabled || element.getAttribute('aria-disabled') === 'true') parts.push('disabled');
    if (tag === 'a' && element.getAttribute('href')) parts.push('href=' + JSON.stringify(clip(element.href, 120)));
    if (!inView(element)) parts.push('(scroll to see)');
    return parts.join(' ');
  }

  /** The page's elements you can use, with refs, and its headings; optionally only those that match `query`. */
  function find(params = {}) {
    const limit = Math.max(1, Math.min(Number(params.limit) || 150, 400));
    const query = clean(params.query).toLowerCase();
    const nodes = deepAll(INTERACTIVE + ',' + HEADINGS);
    const onlyInView = !!params.inView;
    const lines = [];
    let more = 0;
    for (const element of nodes) {
      if (!shown(element) || element.type === 'hidden') continue;
      if (onlyInView && !inView(element)) continue;
      const tag = element.tagName.toLowerCase();
      // A link or button inside another one is the same control.
      if (!/^h[1-3]$/.test(tag) && element.parentElement?.closest(INTERACTIVE) && !element.matches('input,textarea,select')) continue;
      const text = /^h[1-3]$/.test(tag) ? `${tag} ${JSON.stringify(clip(nameOf(element), 100))}` : line(element, refFor(element));
      if (query && !text.toLowerCase().includes(query)) continue;
      if (lines.length >= limit) {
        more += 1;
        continue;
      }
      lines.push(text);
    }
    const head = `${document.title || '(no title)'} | ${location.href}`;
    if (!lines.length) {
      return { ok: true, text: head + '\n\n' + (query ? `Nothing on the page matches "${params.query}".` : 'The page has no elements to use (yet).') };
    }
    const tail = more ? `\n… ${more} more; pass query to narrow it down.` : '';
    return { ok: true, text: `${head}\n\n${lines.join('\n')}${tail}\n\nUse a ref with chrome_click or chrome_type. Refs stay valid until the page reloads.` };
  }

  /** The readable text of the page: its main part when it has one, the selection, and where it scrolled to. */
  function read(params = {}) {
    const limit = Math.max(500, Math.min(Number(params.limit) || TEXT_LIMIT, 100_000));
    const root = document.querySelector('main, [role=main], article') || document.body;
    // innerText lays the page out; it is read once per part, not again for the length check.
    const main = root?.innerText || '';
    const text = root !== document.body && clean(main).length <= 200 ? document.body?.innerText || '' : main;
    const tidy = text.replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
    const selection = clean(String(getSelection() || ''));
    // For a question from the side panel: the text and the selection apart, without the header Nook adds itself.
    if (params.plain) {
      const body = tidy.length > limit ? tidy.slice(0, limit) + `\n… (${tidy.length - limit} more characters; the page is long)` : tidy;
      return { ok: true, text: body, selection: clip(selection, 2_000) };
    }
    const scrolled = document.documentElement.scrollHeight > innerHeight
      ? Math.round((scrollY / Math.max(1, document.documentElement.scrollHeight - innerHeight)) * 100) : null;
    const lines = [`# ${document.title || '(no title)'}`, location.href];
    if (scrolled !== null) lines.push(`Scrolled ${scrolled}% down.`);
    if (selection) lines.push(`The user selected: "${clip(selection, 2_000)}"`);
    lines.push('', tidy.length > limit ? tidy.slice(0, limit) + `\n… (${tidy.length - limit} more characters; the page is long)` : tidy || '(The page shows no text.)');
    return { ok: true, text: lines.join('\n') };
  }

  /**
   * The element a target points at: a ref, a CSS selector, or visible text. For text, what the user can see wins: an
   * exact name before one that starts with it before one that contains it, in view before off screen, and a button or
   * link before a label.
   */
  function locate(target) {
    if (target.ref) {
      const element = elementOf.get(target.ref)?.deref();
      return element && element.isConnected ? element : null;
    }
    if (target.selector) {
      try {
        return document.querySelector(target.selector) || deepAll(target.selector)[0] || null;
      } catch {
        throw new Error('That is not a valid CSS selector.');
      }
    }
    const want = clean(target.text).toLowerCase();
    if (!want) return null;
    let best = null;
    let bestScore = 0;
    for (const candidate of deepAll(INTERACTIVE + ',label,option')) {
      const name = nameOf(candidate).toLowerCase();
      if (!name.includes(want)) continue;
      let score = name === want ? 60 : name.startsWith(want) ? 40 : 20;
      if (!shown(candidate) && candidate.tagName !== 'OPTION') continue;
      if (inView(candidate)) score += 15;
      if (!['LABEL', 'OPTION'].includes(candidate.tagName)) score += 5;
      if (candidate.disabled || candidate.getAttribute('aria-disabled') === 'true') score -= 30;
      // A shorter name that contains the words is closer to what was asked than a long paragraph that does.
      score -= Math.min(10, Math.floor((name.length - want.length) / 20));
      if (score > bestScore) {
        best = candidate;
        bestScore = score;
      }
    }
    return best;
  }

  function describe(element) {
    const name = clip(nameOf(element), 80);
    return roleOf(element) + (name ? ` "${name}"` : '');
  }

  function element(params) {
    let found;
    try {
      found = locate(params);
    } catch (error) {
      return { error: error.message };
    }
    if (!found) {
      return { error: params.ref ? `Ref ${params.ref} is no longer on the page. Call chrome_find again.` : 'No such element on the page. Call chrome_find to see what is there.' };
    }
    return { found };
  }

  /**
   * Something the user cannot click through lies over the point (a cookie banner, a dialog, a sticky bar): the element
   * that covers it, or null when the click lands on the target, inside it, or on its label.
   */
  function coverAt(target, x, y) {
    const hit = elementAt(x, y);
    if (!hit || hit === target || target.contains(hit) || hit.contains(target)) return null;
    const label = hit.closest('label');
    if (label && (label.control === target || label.contains(target))) return null;
    // Only a layer that floats over the page counts; an element merely next to it in a custom control does not.
    for (let node = hit, depth = 0; node && depth < 12; node = node.parentElement, depth += 1) {
      const position = getComputedStyle(node).position;
      if (node.matches?.('dialog,[role=dialog],[role=alertdialog],[aria-modal=true]') || position === 'fixed' || position === 'sticky') {
        return node;
      }
    }
    return null;
  }

  /** Clicks like a person: the cursor goes there, then pointer and mouse events at that point, then the click. */
  async function click(params) {
    const { found, error } = element(params);
    if (error) return { ok: false, error };
    if (found.tagName === 'OPTION') {
      const select = found.closest('select');
      if (!select) return { ok: false, error: `${describe(found)} is not in a list you can choose from.` };
      await reveal(select);
      const at = centerOf(select);
      await moveTo(at.x, at.y, `${say('cursorChoose')} · ${short(found)}`, params._from);
      pulse();
      select.value = found.value;
      select.dispatchEvent(new Event('input', { bubbles: true }));
      select.dispatchEvent(new Event('change', { bubbles: true }));
      return { ok: true, element: describe(found), cursor: where(), text: `Chose ${describe(found)}.` };
    }
    const target = found;
    if (target.disabled || target.getAttribute('aria-disabled') === 'true') return { ok: false, error: `${describe(target)} is disabled.` };
    await reveal(target);
    let at = centerOf(target);
    await moveTo(at.x, at.y, `${say('cursorClick')} · ${short(target)}`, params._from);
    // The page may have moved while the cursor glided (a lazy image, an animation): click where it is now.
    at = centerOf(target);
    const cover = coverAt(target, at.x, at.y);
    if (cover) {
      // Name the layer's own buttons with refs, so Nook can close or accept it in one step.
      const buttons = deepAll(INTERACTIVE, cover.shadowRoot || cover).filter(shown).slice(0, 5)
        .map((button) => `[${refFor(button)}] ${describe(button)}`);
      const says = clip(clean(cover.innerText), 80);
      return {
        ok: false, cursor: where(),
        error: `${describe(target)} is covered by a banner or dialog over the page${says ? ` ("${says}")` : ''}. `
          + (buttons.length ? `Its buttons: ${buttons.join(', ')}. Click the one that closes or accepts it, then try again.` : 'Close it first (Escape, or its close button), then try again.')
      };
    }
    const init = { bubbles: true, cancelable: true, composed: true, view: window, clientX: at.x, clientY: at.y, button: 0 };
    pulse();
    target.dispatchEvent(new PointerEvent('pointerover', init));
    target.dispatchEvent(new PointerEvent('pointerenter', { ...init, bubbles: false }));
    target.dispatchEvent(new MouseEvent('mouseover', init));
    target.dispatchEvent(new PointerEvent('pointermove', init));
    target.dispatchEvent(new MouseEvent('mousemove', init));
    target.dispatchEvent(new PointerEvent('pointerdown', { ...init, buttons: 1 }));
    target.dispatchEvent(new MouseEvent('mousedown', { ...init, buttons: 1 }));
    if (target.focus) target.focus({ preventScroll: true });
    target.dispatchEvent(new PointerEvent('pointerup', init));
    target.dispatchEvent(new MouseEvent('mouseup', init));
    target.click();
    return { ok: true, element: describe(target), cursor: where(), text: `Clicked ${describe(target)}.` };
  }

  /** Sets a field's value through its own setter and says so, so frameworks such as React see it. */
  function setValue(field, next, data) {
    const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), 'value')?.set;
    if (setter) setter.call(field, next);
    else field.value = next;
    field.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data }));
  }

  /**
   * Types into a field. Short text goes in a few quick steps, as a person types, so search fields and suggestions react
   * as they do for the user; long text goes at once. Never into a password field.
   */
  async function type(params) {
    const { found, error } = element(params);
    if (error) return { ok: false, error };
    const field = found.tagName === 'LABEL' && found.control ? found.control : found;
    if (secret(field)) {
      return { ok: false, signIn: true, error: 'Nook does not type into password or sign-in code fields; the user signs in themselves.' };
    }
    if (field.disabled || field.readOnly) return { ok: false, error: `${describe(field)} cannot be edited.` };
    const value = String(params.value ?? '');
    await reveal(field);
    const at = centerOf(field);
    const isSelect = field.tagName === 'SELECT';
    await moveTo(at.x, at.y, `${say(isSelect ? 'cursorChoose' : 'cursorType')} · ${clip(value, 28) || short(field)}`, params._from);
    pulse();
    field.focus?.({ preventScroll: true });
    if (isSelect) {
      const want = value.trim().toLowerCase();
      const option = Array.from(field.options).find((o) => clean(o.text).toLowerCase() === want || o.value.toLowerCase() === want)
        || Array.from(field.options).find((o) => clean(o.text).toLowerCase().includes(want));
      if (!option) return { ok: false, cursor: where(), error: `${describe(field)} has no option "${value}". It has: ${Array.from(field.options).slice(0, 15).map((o) => clean(o.text)).join(', ')}.` };
      field.value = option.value;
      field.dispatchEvent(new Event('input', { bubbles: true }));
      field.dispatchEvent(new Event('change', { bubbles: true }));
      return { ok: true, element: describe(field), cursor: where(), text: `Chose "${clean(option.text)}" in ${describe(field)}.` };
    }
    if (field.isContentEditable) {
      if (!params.append) document.execCommand('selectAll', false, null);
      document.execCommand('insertText', false, value);
    } else if ('value' in field) {
      const start = params.append ? String(field.value || '') : '';
      if (!still() && value.length > 1 && value.length <= 80) {
        const steps = Math.min(8, value.length);
        const size = Math.ceil(value.length / steps);
        for (let index = size; index < value.length + size; index += size) {
          // A page that replaced the field while Nook typed (some frameworks redraw it on input): stop, and say so
          // below, rather than type the rest into a field nobody sees.
          if (!field.isConnected) break;
          setValue(field, start + value.slice(0, index), value.slice(index - size, index));
          await sleep(18);
        }
        if (!field.isConnected) {
          return { ok: false, cursor: where(), error: `The page replaced ${describe(field)} while Nook typed. Look with chrome_find and type again into the field that is there now.` };
        }
      } else {
        setValue(field, start + value, value);
      }
      field.dispatchEvent(new Event('change', { bubbles: true }));
    } else {
      return { ok: false, cursor: where(), error: `${describe(field)} is not a field you can type in.` };
    }
    let submitted = false;
    if (params.submit) {
      const form = field.form || field.closest?.('form');
      if (form?.requestSubmit) {
        form.requestSubmit();
      } else {
        for (const kind of ['keydown', 'keypress', 'keyup']) {
          field.dispatchEvent(new KeyboardEvent(kind, { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true }));
        }
      }
      submitted = true;
    }
    const verb = submitted ? 'Typed into and submitted' : 'Typed into';
    return { ok: true, element: describe(field), submitted, cursor: where(), text: `${verb} ${describe(field)}.` };
  }

  /** Scrolls the page (or an element into view): up, down, top, bottom, by a screen at a time, smoothly. */
  async function scroll(params = {}) {
    if (params.ref || params.selector || params.text) {
      const { found, error } = element(params);
      if (error) return { ok: false, error };
      await moveTo(innerWidth * 0.62, innerHeight * 0.5, `${say('cursorScroll')} · ${short(found)}`, params._from);
      found.scrollIntoView({ block: 'center', behavior: still() ? 'instant' : 'smooth' });
      await scrolled();
      return { ok: true, cursor: where(), text: `Scrolled ${describe(found)} into view.\n\n${glance().text}` };
    }
    const screens = Math.max(0.25, Math.min(Number(params.amount) || 1, 10));
    const step = innerHeight * 0.85 * screens;
    const up = params.direction === 'up' || params.direction === 'top';
    await moveTo(innerWidth * 0.62, innerHeight * 0.5, `${say('cursorScroll')} ${up ? '↑' : '↓'}`, params._from);
    const behavior = still() ? 'instant' : 'smooth';
    switch (params.direction) {
      case 'up': scrollBy({ top: -step, behavior }); break;
      case 'top': scrollTo({ top: 0, behavior }); break;
      case 'bottom': scrollTo({ top: document.documentElement.scrollHeight, behavior }); break;
      default: scrollBy({ top: step, behavior });
    }
    await scrolled();
    const max = Math.max(1, document.documentElement.scrollHeight - innerHeight);
    return { ok: true, cursor: where(), text: `Scrolled; now ${Math.round((scrollY / max) * 100)}% down the page.\n\n${glance().text}` };
  }

  /** Until a smooth scroll ends: at once when nothing moves (already at the end), at most 700 ms. */
  function scrolled() {
    return new Promise((resolve) => {
      let done = false;
      let moved = false;
      const onScroll = () => { moved = true; };
      const finish = () => {
        if (done) return;
        done = true;
        removeEventListener('scroll', onScroll, true);
        removeEventListener('scrollend', finish, true);
        resolve();
      };
      addEventListener('scroll', onScroll, true);
      addEventListener('scrollend', finish, true);
      setTimeout(() => { if (!moved) finish(); }, 120);
      setTimeout(finish, still() ? 60 : 700);
    });
  }

  const KEYS = {
    enter: ['Enter', 13], escape: ['Escape', 27], esc: ['Escape', 27], tab: ['Tab', 9], backspace: ['Backspace', 8],
    delete: ['Delete', 46], space: [' ', 32], arrowup: ['ArrowUp', 38], arrowdown: ['ArrowDown', 40],
    arrowleft: ['ArrowLeft', 37], arrowright: ['ArrowRight', 39], pageup: ['PageUp', 33], pagedown: ['PageDown', 34],
    home: ['Home', 36], end: ['End', 35]
  };

  /**
   * Presses a key on the focused element (or a target). A page sees these as script events, so the browser's own
   * default (a new line, moving focus) does not follow; Enter in a form field submits the form, Tab moves focus.
   */
  async function key(params) {
    let target = document.activeElement || document.body;
    if (params.ref || params.selector || params.text) {
      const { found, error } = element(params);
      if (error) return { ok: false, error };
      target = found;
      await reveal(target);
      target.focus?.();
    }
    const name = String(params.key).trim();
    // Own keys only: "constructor" or "__proto__" must not resolve to Object's prototype.
    const [keyName, code] = (Object.hasOwn(KEYS, name.toLowerCase()) && KEYS[name.toLowerCase()]) || [name, name.length === 1 ? name.toUpperCase().charCodeAt(0) : 0];
    const at = target && target !== document.body && target.getBoundingClientRect().width ? centerOf(target)
      : { x: cursor.x ?? innerWidth / 2, y: cursor.y ?? innerHeight / 2 };
    await moveTo(at.x, at.y, say('cursorKey', keyName === ' ' ? 'Space' : keyName), params._from);
    pulse();
    const init = { key: keyName, code: keyName.length === 1 ? 'Key' + keyName.toUpperCase() : keyName, keyCode: code, which: code, bubbles: true, cancelable: true, composed: true };
    const proceed = target.dispatchEvent(new KeyboardEvent('keydown', init));
    if (keyName.length === 1) target.dispatchEvent(new KeyboardEvent('keypress', init));
    target.dispatchEvent(new KeyboardEvent('keyup', init));
    let effect = '';
    if (proceed && keyName === 'Enter' && target.form && target.tagName === 'INPUT') {
      target.form.requestSubmit?.();
      effect = ' and submitted the form';
    } else if (proceed && keyName === 'Tab') {
      const focusable = deepAll(INTERACTIVE).filter((e) => shown(e) && !e.disabled && e.tabIndex >= 0);
      const index = focusable.indexOf(target);
      focusable[(index + 1) % focusable.length]?.focus();
      effect = ' and moved to the next field';
    }
    return { ok: true, cursor: where(), text: `Pressed ${keyName} on ${describe(target)}${effect}.` };
  }

  /** Whether text or an element is on the page (or gone) now; the service worker asks again until it is. */
  function condition(params = {}) {
    let found = true;
    if (params.text) found = (document.body?.innerText || '').includes(params.text);
    if (found && params.selector) {
      try {
        found = !!document.querySelector(params.selector) || deepAll(params.selector).length > 0;
      } catch {
        return { ok: false, error: 'That is not a valid CSS selector.' };
      }
    }
    return { ok: true, met: params.gone ? !found : found };
  }

  /**
   * Waits until the page stops changing after an action (a menu opening, results coming in): no change for `idle` ms,
   * at most `limit` ms. So the next look sees what the action did, without a fixed wait.
   */
  function quiet(params = {}) {
    // In a background tab every timer waits about a second anyway: one wait is enough there.
    const idle = document.hidden ? 0 : Math.max(50, Math.min(Number(params.idle) || 160, 1000));
    const limit = Math.max(idle, Math.min(Number(params.limit) || 1500, 5000));
    return new Promise((resolve) => {
      const started = Date.now();
      let timer = null;
      const observer = new MutationObserver(() => {
        clearTimeout(timer);
        timer = setTimeout(done, idle);
      });
      const done = () => {
        observer.disconnect();
        clearTimeout(timer);
        clearTimeout(cap);
        resolve({ ok: true, waited: Date.now() - started });
      };
      const cap = setTimeout(done, limit);
      observer.observe(document.documentElement, { subtree: true, childList: true, attributes: true, characterData: true });
      timer = setTimeout(done, idle);
    });
  }

  /**
   * What the user sees now, in short: the page and what can be used in view. It goes with the result of every action, so
   * Nook can take the next step without first looking again (one round less each time).
   */
  function glance(params = {}) {
    const limit = Math.max(5, Math.min(Number(params.limit) || 30, 80));
    const look = find({ limit, inView: true });
    const lines = look.text.split('\n\n')[1] || '(nothing to use in view)';
    const dialog = deepAll('dialog[open],[role=dialog],[role=alertdialog],[aria-modal=true]').find(shown);
    const head = `Now: ${document.title || '(no title)'} | ${location.href}` + (dialog ? `\nA dialog is open: ${describe(dialog)}.` : '');
    return { ok: true, text: `${head}\nIn view:\n${lines}` };
  }

  /**
   * Whether the page asks the user to sign in: a password field they can see, or a field for a one-time code. Nook
   * never types there; it lets the user sign in and goes on after. Nothing of what is in those fields is read.
   */
  function signin() {
    const fields = deepAll('input[type=password],input[autocomplete~="one-time-code"],input[name*=otp i],input[id*=otp i]')
      .filter((field) => shown(field) && !field.disabled);
    const site = location.hostname.replace(/^www\./, '');
    return { ok: true, needed: fields.length > 0, site, url: location.href };
  }

  async function run(method, params) {
    try {
      const handler = { find, read, click, type, scroll, key, condition, quiet, glance, signin }[method];
      if (!handler) return { ok: false, error: `The page agent has no ${method}.` };
      return await handler(params || {});
    } catch (error) {
      return { ok: false, error: String(error?.message || error) };
    }
  }

  Object.defineProperty(globalThis, '__nookAgent', { value: Object.freeze({ run }), configurable: false });
})();
