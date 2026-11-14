// While Nook clicks, types or presses keys on a page, a glow around the page and a small strip at the bottom say so,
// with a Stop button that pauses Nook in this whole browser. Injected into the page's isolated world before each
// action; it fades a few seconds after the last one. Its elements live in a closed shadow root, so the page's styles
// cannot hide or restyle it.
(() => {
  const holdMs = 4000;
  const state = globalThis.__nookPresence || (globalThis.__nookPresence = { host: null, timer: null });

  if (!state.host || !state.host.isConnected) {
    const host = document.createElement('nook-presence');
    host.style.cssText = 'all:initial;position:fixed;inset:0;z-index:2147483646;pointer-events:none';
    const root = host.attachShadow({ mode: 'closed' });
    const label = chrome.i18n.getMessage('presenceWorking') || 'Nook is working in this tab';
    const stop = chrome.i18n.getMessage('presenceStop') || 'Stop';
    root.innerHTML = `
      <style>
        :host { all: initial; }
        .glow { position: fixed; inset: 0; box-shadow: inset 0 0 0 2px rgba(124,108,240,.85), inset 0 0 28px rgba(124,108,240,.35);
                opacity: 0; transition: opacity .25s ease-out; }
        .strip { position: fixed; left: 50%; bottom: 18px; transform: translate(-50%, 8px); opacity: 0;
                 transition: opacity .25s ease-out, transform .25s ease-out; display: flex; align-items: center; gap: 10px;
                 padding: 7px 8px 7px 14px; border-radius: 999px; background: rgba(22,22,28,.92); color: #f3f2f8;
                 font: 500 13px/1.2 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; pointer-events: auto;
                 box-shadow: 0 6px 24px rgba(0,0,0,.28); }
        .dot { width: 8px; height: 8px; border-radius: 50%; background: #7c6cf0; }
        button { all: unset; cursor: pointer; padding: 5px 12px; border-radius: 999px; background: #e0605a; color: #fff; font-weight: 600; }
        button:focus-visible { outline: 2px solid #fff; outline-offset: 2px; }
        .on .glow { opacity: 1; }
        .on .strip { opacity: 1; transform: translate(-50%, 0); }
        @media (prefers-reduced-motion: reduce) { .glow, .strip { transition: none; } }
      </style>
      <div class="wrap"><div class="glow"></div><div class="strip" role="status"><span class="dot"></span><span></span><button type="button"></button></div></div>`;
    root.querySelector('.strip span:not(.dot)').textContent = label;
    const button = root.querySelector('button');
    button.textContent = stop;
    button.addEventListener('click', async () => {
      // The strip only goes away once Nook is really paused: when the extension was reloaded or its worker cannot be
      // reached, it stays, so the user never thinks Nook stopped while it did not.
      try {
        const reply = await chrome.runtime.sendMessage({ type: 'pause', paused: true });
        if (reply?.ok) state.wrap.classList.remove('on');
      } catch {
        // "Extension context invalidated": this page outlived the extension that drew the strip.
      }
    });
    state.wrap = root.querySelector('.wrap');
    state.host = host;
    document.documentElement.appendChild(host);
  }

  requestAnimationFrame(() => state.wrap.classList.add('on'));
  clearTimeout(state.timer);
  state.timer = setTimeout(() => state.wrap.classList.remove('on'), holdMs);
})();
