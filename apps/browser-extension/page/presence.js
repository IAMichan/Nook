// While Nook clicks, types or presses keys on a page, a glow around the page and a small strip at the bottom say so,
// with a Stop button that pauses Nook in this whole browser. Injected into the page's isolated world before each
// action; it fades a few seconds after the last one. Its elements live in a closed shadow root, so the page's styles
// cannot hide or restyle it. It wears Nook's theme (the look the side panel keeps): the strip in the color of Nook's
// menus, the glow in its violet.
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
        .wrap { --glow: #b0a2e6; --menu: #171717; --paper: #f5f5f5; --line: #262626; --coral: #ff6467; }
        .glow { position: fixed; inset: 0;
                box-shadow: inset 0 0 0 2px color-mix(in srgb, var(--glow) 85%, transparent),
                            inset 0 0 28px color-mix(in srgb, var(--glow) 35%, transparent);
                opacity: 0; transition: opacity .25s ease-out; }
        .strip { position: fixed; left: 50%; bottom: 18px; transform: translate(-50%, 8px); opacity: 0;
                 transition: opacity .25s ease-out, transform .25s ease-out; display: flex; align-items: center; gap: 10px;
                 padding: 6px 6px 6px 14px; border-radius: 12px; background: color-mix(in srgb, var(--menu) 94%, transparent);
                 border: 1px solid var(--line); color: var(--paper); backdrop-filter: blur(12px);
                 font: 500 13px/1.2 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif; pointer-events: auto;
                 box-shadow: 0 8px 28px rgba(0,0,0,.32); }
        .dot { width: 7px; height: 7px; border-radius: 50%; background: var(--glow); animation: pulse 1.6s ease-in-out infinite; }
        @keyframes pulse { 50% { opacity: .35; } }
        button { all: unset; cursor: pointer; padding: 5px 12px; border-radius: 8px; background: var(--coral); color: #fff; font-weight: 600; }
        button:hover { filter: brightness(1.08); }
        button:focus-visible { outline: 2px solid var(--paper); outline-offset: 2px; }
        .on .glow { opacity: 1; }
        .on .strip { opacity: 1; transform: translate(-50%, 0); }
        @media (prefers-reduced-motion: reduce) { .glow, .strip { transition: none; } .dot { animation: none; } }
      </style>
      <div class="wrap"><div class="glow"></div><div class="strip" role="status"><span class="dot"></span><span></span><button type="button"></button></div></div>`;
    root.querySelector('.strip span:not(.dot)').textContent = label;
    const button = root.querySelector('button');
    button.textContent = stop;
    button.addEventListener('click', () => {
      chrome.runtime.sendMessage({ type: 'pause', paused: true });
      state.wrap.classList.remove('on');
    });
    state.wrap = root.querySelector('.wrap');
    state.host = host;
    // Nook's theme, from the look the side panel keeps; only #RRGGBB values, so nothing else reaches the style.
    chrome.storage.local.get('look').then(({ look }) => {
      const colors = look?.dark || {};
      for (const [name, token] of [['--glow', 'violet'], ['--menu', 'menu'], ['--paper', 'paper'], ['--line', 'line2'], ['--coral', 'coral']]) {
        if (/^#[0-9a-f]{6}$/i.test(colors[token] || '')) state.wrap.style.setProperty(name, colors[token]);
      }
    }).catch(() => {});
    document.documentElement.appendChild(host);
  }

  requestAnimationFrame(() => state.wrap.classList.add('on'));
  clearTimeout(state.timer);
  state.timer = setTimeout(() => state.wrap.classList.remove('on'), holdMs);
})();
