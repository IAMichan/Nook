// While Nook works on a page, a glow around the page and a strip at the bottom say so, with a Stop button that pauses
// Nook in this whole browser. Meanwhile the user's own clicks and keys on this page are held back, so a stray click
// cannot get in Nook's way; Nook's own events come from a script (not trusted) and pass, and so does the strip itself.
// Scrolling and looking stay free. When the page asks to sign in, Nook steps aside: the user types and clicks as
// always, and Nook goes on by itself once they are in (or when they press Continue).
//
// Injected into the page's isolated world; the service worker then calls `__nookPresence.busy(ms)`, `.signIn()` or
// `.release()`. Its elements live in a closed shadow root, so the page's styles cannot hide or restyle it.
(() => {
  if (globalThis.__nookPresence) return;

  const say = (key) => {
    try {
      return chrome.i18n.getMessage(key) || '';
    } catch {
      return '';
    }
  };

  const state = { host: null, wrap: null, label: null, go: null, mode: 'idle', until: 0, timer: null, nudge: null, acting: false };

  function build() {
    if (state.host?.isConnected) return;
    const host = document.createElement('nook-presence');
    host.style.cssText = 'all:initial;position:fixed;inset:0;z-index:2147483646;pointer-events:none';
    const root = host.attachShadow({ mode: 'closed' });
    root.innerHTML = `
      <style>
        :host { all: initial; }
        .glow { position: fixed; inset: 0; box-shadow: inset 0 0 0 2px rgba(124,108,240,.85), inset 0 0 28px rgba(124,108,240,.35);
                opacity: 0; transition: opacity .25s ease-out; }
        .strip { position: fixed; left: 50%; bottom: 18px; transform: translate(-50%, 8px); opacity: 0; max-width: calc(100vw - 32px);
                 transition: opacity .25s ease-out, transform .25s ease-out; display: flex; align-items: center; gap: 10px;
                 padding: 7px 8px 7px 14px; border-radius: 999px; background: rgba(22,22,28,.92); color: #f3f2f8;
                 font: 500 13px/1.25 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; pointer-events: auto;
                 box-shadow: 0 6px 24px rgba(0,0,0,.28); }
        .dot { flex: none; width: 8px; height: 8px; border-radius: 50%; background: #7c6cf0; }
        .label { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        button { all: unset; flex: none; cursor: pointer; padding: 5px 12px; border-radius: 999px; background: #e0605a; color: #fff; font-weight: 600; }
        button.go { background: #7c6cf0; }
        button:focus-visible { outline: 2px solid #fff; outline-offset: 2px; }
        .on .glow { opacity: 1; }
        .on .strip { opacity: 1; transform: translate(-50%, 0); }
        .login .glow { opacity: 0; }
        .login .dot { background: #e0a23a; }
        .nudge .strip { animation: nudge .35s ease-out; }
        @keyframes nudge { 0%, 100% { transform: translate(-50%, 0); } 30% { transform: translate(calc(-50% - 5px), 0); } 60% { transform: translate(calc(-50% + 5px), 0); } }
        @media (prefers-reduced-motion: reduce) { .glow, .strip { transition: none; } .nudge .strip { animation: none; } }
      </style>
      <div class="wrap"><div class="glow"></div><div class="strip" role="status"><span class="dot"></span><span class="label"></span><button type="button" class="go" hidden></button><button type="button" class="stop"></button></div></div>`;
    state.wrap = root.querySelector('.wrap');
    state.label = root.querySelector('.label');
    state.go = root.querySelector('.go');
    const stop = root.querySelector('.stop');
    stop.textContent = say('presenceStop') || 'Stop';
    stop.addEventListener('click', () => {
      chrome.runtime.sendMessage({ type: 'pause', paused: true }).catch(() => {});
      release();
    });
    state.go.textContent = say('presenceSignedIn') || 'Continue';
    state.go.addEventListener('click', () => {
      chrome.runtime.sendMessage({ type: 'signedIn' }).catch(() => {});
    });
    state.host = host;
    document.documentElement.appendChild(host);
  }

  function show(text) {
    build();
    state.label.textContent = text;
    state.wrap.classList.toggle('login', state.mode === 'login');
    state.go.hidden = state.mode !== 'login';
    requestAnimationFrame(() => state.wrap.classList.add('on'));
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
    if (!event.isTrusted || state.mode !== 'busy' || Date.now() > state.until || state.acting) return;
    // The strip itself (Stop) always works.
    if (state.host && event.composedPath().includes(state.host)) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    if (SAYS.has(event.type)) nudge();
  }

  /** The user tried to click or type: say once, briefly, why nothing happens, then show the usual text again. */
  function nudge() {
    if (!state.wrap) return;
    state.label.textContent = say('presenceBlocked') || 'Nook is working here; your clicks wait until it is done.';
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
    /** Set by the page agent while it acts, so its own focus and editing pass as well. */
    acting(on) { state.acting = !!on; },
    get mode() { return state.mode; }
  });
})();
