// Nook's hands on a web page. The service worker injects this file into the page's isolated world (the page's own
// scripts cannot see or change it) and then calls `globalThis.__nookAgent[method](params)`. Every method returns a
// plain object: `{ ok: true, text, … }` or `{ ok: false, error }`. Nothing here sends anything anywhere: the result goes
// back to the service worker, and from there to Nook on this Mac.
//
// Refs ("e7") point at elements through a WeakMap, never through attributes on the page, so the page cannot read or
// forge them. A ref stays the same for the same element across snapshots.
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

  function shown(element) {
    if (!element.isConnected || element.getClientRects().length === 0) return false;
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

  /** One line for an element in a snapshot. Passwords never show their value. */
  function line(element, ref) {
    const parts = [`[${ref}] ${roleOf(element)}`];
    const name = clip(nameOf(element), 100);
    if (name) parts.push(JSON.stringify(name));
    const tag = element.tagName.toLowerCase();
    if (tag === 'input' || tag === 'textarea' || tag === 'select') {
      if (element.placeholder && !name.includes(element.placeholder)) parts.push('placeholder=' + JSON.stringify(clip(element.placeholder, 60)));
      if (element.type === 'password') {
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
    const nodes = document.querySelectorAll(INTERACTIVE + ',' + HEADINGS);
    const lines = [];
    let more = 0;
    for (const element of nodes) {
      if (!shown(element) || element.type === 'hidden') continue;
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
    const text = clean(root?.innerText || '').length > 200 ? root.innerText : document.body?.innerText || '';
    const tidy = text.replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
    const selection = clean(String(getSelection() || ''));
    const scrolled = document.documentElement.scrollHeight > innerHeight
      ? Math.round((scrollY / Math.max(1, document.documentElement.scrollHeight - innerHeight)) * 100) : null;
    const lines = [`# ${document.title || '(no title)'}`, location.href];
    if (scrolled !== null) lines.push(`Scrolled ${scrolled}% down.`);
    if (selection) lines.push(`The user selected: "${clip(selection, 2_000)}"`);
    lines.push('', tidy.length > limit ? tidy.slice(0, limit) + `\n… (${tidy.length - limit} more characters; the page is long)` : tidy || '(The page shows no text.)');
    return { ok: true, text: lines.join('\n') };
  }

  /** The element a target points at: a ref, a CSS selector, or visible text (exact first, then a part of it). */
  function locate(target) {
    if (target.ref) {
      const element = elementOf.get(target.ref)?.deref();
      return element && element.isConnected ? element : null;
    }
    if (target.selector) {
      try {
        return document.querySelector(target.selector);
      } catch {
        throw new Error('That is not a valid CSS selector.');
      }
    }
    const want = clean(target.text).toLowerCase();
    const all = Array.from(document.querySelectorAll(INTERACTIVE + ',label,option')).filter(shown);
    return all.find((e) => nameOf(e).toLowerCase() === want) || all.find((e) => nameOf(e).toLowerCase().includes(want)) || null;
  }

  function describe(element) {
    const name = clip(nameOf(element), 80);
    return roleOf(element) + (name ? ` "${name}"` : '');
  }

  /** A ring where Nook acts, in Nook's color, so the user sees where it clicks or types. Drawn only, never in the way. */
  function mark(element) {
    const box = element.getBoundingClientRect();
    const ring = document.createElement('div');
    ring.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;width:24px;height:24px;border-radius:50%;'
      + 'border:2px solid #7c6cf0;background:rgba(124,108,240,.25);transition:transform .5s ease-out,opacity .5s ease-out;'
      + `left:${box.left + box.width / 2 - 12}px;top:${box.top + box.height / 2 - 12}px`;
    document.documentElement.appendChild(ring);
    requestAnimationFrame(() => {
      ring.style.transform = 'scale(1.9)';
      ring.style.opacity = '0';
    });
    setTimeout(() => ring.remove(), 700);
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

  /** Clicks like a person: pointer and mouse events at the element's center, then the click. */
  function click(params) {
    const { found, error } = element(params);
    if (error) return { ok: false, error };
    let target = found.tagName === 'OPTION' ? found.closest('select') : found;
    if (found.tagName === 'OPTION' && target) {
      target.value = found.value;
      target.dispatchEvent(new Event('input', { bubbles: true }));
      target.dispatchEvent(new Event('change', { bubbles: true }));
      return { ok: true, element: describe(found), text: `Chose ${describe(found)}.` };
    }
    target = found;
    if (target.disabled || target.getAttribute('aria-disabled') === 'true') return { ok: false, error: `${describe(target)} is disabled.` };
    target.scrollIntoView({ block: 'center', inline: 'center' });
    mark(target);
    const box = target.getBoundingClientRect();
    const at = { bubbles: true, cancelable: true, composed: true, view: window, clientX: box.left + box.width / 2, clientY: box.top + box.height / 2, button: 0 };
    target.dispatchEvent(new PointerEvent('pointerover', at));
    target.dispatchEvent(new MouseEvent('mouseover', at));
    target.dispatchEvent(new PointerEvent('pointerdown', { ...at, buttons: 1 }));
    target.dispatchEvent(new MouseEvent('mousedown', { ...at, buttons: 1 }));
    if (target.focus) target.focus({ preventScroll: true });
    target.dispatchEvent(new PointerEvent('pointerup', at));
    target.dispatchEvent(new MouseEvent('mouseup', at));
    target.click();
    return { ok: true, element: describe(target), text: `Clicked ${describe(target)} on ${location.href}. Check the result with chrome_find or chrome_read.` };
  }

  /** Types through the field's own value setter and fires input and change, so frameworks such as React see it. */
  function type(params) {
    const { found, error } = element(params);
    if (error) return { ok: false, error };
    let field = found.tagName === 'LABEL' && found.control ? found.control : found;
    if (field.type === 'password') {
      return { ok: false, error: 'Nook does not type into password fields. Ask the user to sign in themselves.' };
    }
    if (field.disabled || field.readOnly) return { ok: false, error: `${describe(field)} cannot be edited.` };
    const value = String(params.value ?? '');
    field.scrollIntoView({ block: 'center' });
    mark(field);
    field.focus?.({ preventScroll: true });
    if (field.tagName === 'SELECT') {
      const want = value.trim().toLowerCase();
      const option = Array.from(field.options).find((o) => clean(o.text).toLowerCase() === want || o.value.toLowerCase() === want)
        || Array.from(field.options).find((o) => clean(o.text).toLowerCase().includes(want));
      if (!option) return { ok: false, error: `${describe(field)} has no option "${value}".` };
      field.value = option.value;
      field.dispatchEvent(new Event('input', { bubbles: true }));
      field.dispatchEvent(new Event('change', { bubbles: true }));
      return { ok: true, element: describe(field), text: `Chose "${clean(option.text)}" in ${describe(field)}.` };
    }
    if (field.isContentEditable) {
      if (!params.append) document.execCommand('selectAll', false, null);
      document.execCommand('insertText', false, value);
    } else if ('value' in field) {
      const next = params.append ? String(field.value || '') + value : value;
      const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(field), 'value')?.set;
      if (setter) setter.call(field, next);
      else field.value = next;
      field.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: value }));
      field.dispatchEvent(new Event('change', { bubbles: true }));
    } else {
      return { ok: false, error: `${describe(field)} is not a field you can type in.` };
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
    return { ok: true, element: describe(field), submitted, text: `${verb} ${describe(field)} on ${location.href}.` };
  }

  /** Scrolls the page (or an element into view): up, down, top, bottom, by a screen at a time. */
  function scroll(params = {}) {
    if (params.ref || params.selector || params.text) {
      const { found, error } = element(params);
      if (error) return { ok: false, error };
      found.scrollIntoView({ block: 'center' });
      return { ok: true, text: `Scrolled ${describe(found)} into view.` };
    }
    const screens = Math.max(0.25, Math.min(Number(params.amount) || 1, 10));
    const step = innerHeight * 0.85 * screens;
    switch (params.direction) {
      case 'up': scrollBy({ top: -step }); break;
      case 'top': scrollTo({ top: 0 }); break;
      case 'bottom': scrollTo({ top: document.documentElement.scrollHeight }); break;
      default: scrollBy({ top: step });
    }
    const max = Math.max(1, document.documentElement.scrollHeight - innerHeight);
    return { ok: true, text: `Scrolled; now ${Math.round((scrollY / max) * 100)}% down the page.` };
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
  function key(params) {
    let target = document.activeElement || document.body;
    if (params.ref || params.selector || params.text) {
      const { found, error } = element(params);
      if (error) return { ok: false, error };
      target = found;
      target.focus?.();
    }
    const name = String(params.key).trim();
    const [keyName, code] = KEYS[name.toLowerCase()] || [name, name.length === 1 ? name.toUpperCase().charCodeAt(0) : 0];
    const init = { key: keyName, code: keyName.length === 1 ? 'Key' + keyName.toUpperCase() : keyName, keyCode: code, which: code, bubbles: true, cancelable: true, composed: true };
    const proceed = target.dispatchEvent(new KeyboardEvent('keydown', init));
    if (keyName.length === 1) target.dispatchEvent(new KeyboardEvent('keypress', init));
    target.dispatchEvent(new KeyboardEvent('keyup', init));
    let effect = '';
    if (proceed && keyName === 'Enter' && target.form && target.tagName === 'INPUT') {
      target.form.requestSubmit?.();
      effect = ' and submitted the form';
    } else if (proceed && keyName === 'Tab') {
      const focusable = Array.from(document.querySelectorAll(INTERACTIVE)).filter((e) => shown(e) && !e.disabled && e.tabIndex >= 0);
      const index = focusable.indexOf(target);
      focusable[(index + 1) % focusable.length]?.focus();
      effect = ' and moved to the next field';
    }
    return { ok: true, text: `Pressed ${keyName} on ${describe(target)}${effect}.` };
  }

  /** Whether text or an element is on the page (or gone) now; the service worker asks again until it is. */
  function condition(params = {}) {
    let found = true;
    if (params.text) found = (document.body?.innerText || '').includes(params.text);
    if (found && params.selector) {
      try {
        found = !!document.querySelector(params.selector);
      } catch {
        return { ok: false, error: 'That is not a valid CSS selector.' };
      }
    }
    return { ok: true, met: params.gone ? !found : found };
  }

  function run(method, params) {
    try {
      const handler = { find, read, click, type, scroll, key, condition }[method];
      if (!handler) return { ok: false, error: `The page agent has no ${method}.` };
      return handler(params || {});
    } catch (error) {
      return { ok: false, error: String(error?.message || error) };
    }
  }

  Object.defineProperty(globalThis, '__nookAgent', { value: Object.freeze({ run }), configurable: false });
})();
