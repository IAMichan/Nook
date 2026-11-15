// While Nook works on a page, a glow around the page and a strip at the bottom say so, with a Stop button that pauses
// Nook in this whole browser. Meanwhile the user's own clicks and keys on this page are held back, so a stray click
// cannot get in Nook's way; Nook's own events come from a script (not trusted) and pass, and so does the strip itself.
// Scrolling and looking stay free. When the page asks to sign in, Nook steps aside: the user types and clicks as
// always, and Nook goes on by itself once they are in (or when they press Continue).
//
// Injected into the page's isolated world; the service worker then calls `__nookPresence.busy(ms)`, `.signIn()` or
// `.release()`. Its elements live in a closed shadow root, so the page's styles cannot hide or restyle it. It wears Nook's
// theme (the look the side panel keeps): the strip in the color of Nook's menus, the glow in its violet.
(() => {
  if (globalThis.__nookPresence) return;

  const say = (key) => {
    try {
      return chrome.i18n.getMessage(key) || '';
    } catch {
      return '';
    }
  };

  const state = {
    host: null, wrap: null, label: null, go: null, mode: 'idle', until: 0, timer: null, nudge: null,
    // The user pressed Continue after signing in; the service worker reads it here, so no page can claim it in a message.
    continued: false
  };

  function build() {
    if (state.host?.isConnected) return;
    const host = document.createElement('nook-presence');
    host.style.cssText = 'all:initial;position:fixed;inset:0;z-index:2147483646;pointer-events:none';
    const root = host.attachShadow({ mode: 'closed' });
    root.innerHTML = `
      <style>
        :host { all: initial; }
        .wrap { --glow: #b0a2e6; --menu: #171717; --paper: #f5f5f5; --line: #262626; --coral: #ff6467; --amber: #f0b65a; }
        .glow { position: fixed; inset: 0;
                box-shadow: inset 0 0 0 2px color-mix(in srgb, var(--glow) 85%, transparent),
                            inset 0 0 28px color-mix(in srgb, var(--glow) 35%, transparent);
                opacity: 0; transition: opacity .25s ease-out; }
        .strip { position: fixed; left: 50%; bottom: 18px; transform: translate(-50%, 8px); opacity: 0; max-width: calc(100vw - 32px);
                 transition: opacity .25s ease-out, transform .25s ease-out; display: flex; align-items: center; gap: 10px;
                 padding: 6px 6px 6px 14px; border-radius: 12px; background: color-mix(in srgb, var(--menu) 94%, transparent);
                 border: 1px solid var(--line); color: var(--paper); backdrop-filter: blur(12px);
                 font: 500 13px/1.25 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif; pointer-events: auto;
                 box-shadow: 0 8px 28px rgba(0,0,0,.32); }
        .dot { flex: none; width: 7px; height: 7px; border-radius: 50%; background: var(--glow); animation: pulse 1.6s ease-in-out infinite; }
        @keyframes pulse { 50% { opacity: .35; } }
        .label { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        button { all: unset; flex: none; cursor: pointer; padding: 5px 12px; border-radius: 8px; background: var(--coral); color: #fff; font-weight: 600; }
        button.go { background: var(--glow); color: var(--menu); }
        button:hover { filter: brightness(1.08); }
        button:focus-visible { outline: 2px solid var(--paper); outline-offset: 2px; }
        .on .glow { opacity: 1; }
        .on .strip { opacity: 1; transform: translate(-50%, 0); }
        .login .glow { opacity: 0; }
        .login .dot { background: var(--amber); }
        .nudge .strip { animation: nudge .35s ease-out; }
        @keyframes nudge { 0%, 100% { transform: translate(-50%, 0); } 30% { transform: translate(calc(-50% - 5px), 0); } 60% { transform: translate(calc(-50% + 5px), 0); } }
        @media (prefers-reduced-motion: reduce) { .glow, .strip { transition: none; } .dot, .nudge .strip { animation: none; } }
      </style>
      <div class="wrap"><div class="glow"></div><div class="strip" role="status"><span class="dot"></span><span class="label"></span><button type="button" class="go" hidden></button><button type="button" class="stop"></button></div></div>`;
    state.wrap = root.querySelector('.wrap');
    state.label = root.querySelector('.label');
    state.go = root.querySelector('.go');
    const stop = root.querySelector('.stop');
    stop.textContent = say('presenceStop') || 'Stop';
    stop.addEventListener('click', stopNook);
    state.go.textContent = say('presenceSignedIn') || 'Continue';
    state.go.addEventListener('click', () => {
      state.continued = true;
    });
    state.host = host;
    // Nook's theme, from the look the side panel keeps; only #RRGGBB values, so nothing else reaches the style.
    Promise.resolve(chrome.storage?.local?.get('look')).then(({ look } = {}) => {
      const colors = look?.dark || {};
      for (const [name, token] of [['--glow', 'violet'], ['--menu', 'menu'], ['--paper', 'paper'], ['--line', 'line2'], ['--coral', 'coral'], ['--amber', 'amber']]) {
        if (/^#[0-9a-f]{6}$/i.test(colors[token] || '')) state.wrap.style.setProperty(name, colors[token]);
      }
    }).catch(() => {});
    document.documentElement.appendChild(host);
  }

  /**
   * Pauses Nook in this browser (Stop, or Escape while Nook works). The strip only goes away once Nook is really paused:
   * when the extension was reloaded or its worker cannot be reached, it stays, so the user never thinks Nook stopped
   * while it did not.
   */
  async function stopNook() {
    try {
      const reply = await chrome.runtime.sendMessage({ type: 'pause', paused: true });
      if (reply?.ok) release();
    } catch {
      // "Extension context invalidated": this page outlived the extension that drew the strip.
    }
  }

  function show(text) {
    build();
    state.label.textContent = text;
    state.wrap.classList.toggle('login', state.mode === 'login');
    state.go.hidden = state.mode !== 'login';
    // A tab in the background runs this frame late: only when Nook still works or waits here by then.
    requestAnimationFrame(() => { if (state.mode !== 'idle') state.wrap.classList.add('on'); });
    // A hidden tab draws no frames: show it at once there.
    if (document.hidden) state.wrap.classList.add('on');
  }

  /** Nook works here for the next `holdMs`: the strip shows, and the user's clicks and keys on this page wait. */
  function busy(holdMs = 12_000) {
    state.mode = 'busy';
    state.until = Date.now() + holdMs;
    show(say('presenceWorking') || 'Nook is working in this tab');
    clearTimeout(state.timer);
    state.timer = setTimeout(release, holdMs);
  }

  /** The page asks to sign in: the user's hands are free again, and the strip says Nook goes on once they are in. */
  function signIn() {
    state.mode = 'login';
    state.continued = false;
    state.until = 0;
    clearTimeout(state.timer);
    show(say('presenceSignIn') || 'Sign in on this page; Nook goes on by itself once you are in.');
  }

  function release() {
    state.mode = 'idle';
    state.until = 0;
    clearTimeout(state.timer);
    state.wrap?.classList.remove('on', 'login');
  }

  // MARK: - Holding the user's own input back while Nook works

  const HELD = ['pointerdown', 'pointerup', 'mousedown', 'mouseup', 'click', 'dblclick', 'auxclick', 'contextmenu',
    'keydown', 'keypress', 'keyup', 'beforeinput', 'paste', 'drop', 'touchstart', 'touchend',
    'pointerover', 'pointerout', 'pointermove', 'mouseover', 'mouseout', 'mousemove'];
  const SAYS = new Set(['pointerdown', 'keydown', 'touchstart']);

  function hold(event) {
    if (!event.isTrusted || state.mode !== 'busy' || Date.now() > state.until) return;
    // The strip itself (Stop) always works.
    if (state.host && event.composedPath().includes(state.host)) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    // Escape is Stop from the keyboard: Tab cannot reach the strip's button while the page's keys wait.
    if (event.type === 'keydown' && event.key === 'Escape') {
      stopNook();
      return;
    }
    if (SAYS.has(event.type)) nudge();
  }

  /** The user tried to click or type: say once, briefly, why nothing happens, then show the usual text again. */
  function nudge() {
    if (!state.wrap) return;
    state.label.textContent = say('presenceBlocked') || 'Nook is working here; your clicks wait until it is done. Esc stops Nook.';
    state.wrap.classList.remove('nudge');
    void state.wrap.offsetWidth;
    state.wrap.classList.add('nudge');
    clearTimeout(state.nudge);
    state.nudge = setTimeout(() => {
      if (state.mode === 'busy') state.label.textContent = say('presenceWorking') || 'Nook is working in this tab';
    }, 1_800);
  }

  for (const type of HELD) addEventListener(type, hold, { capture: true, passive: false });

  globalThis.__nookPresence = Object.freeze({
    busy, signIn, release,
    get mode() { return state.mode; },
    get continued() { return state.continued; }
  });
})();
