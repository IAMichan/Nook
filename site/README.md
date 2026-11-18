# Nook website

A static site with no dependencies: plain HTML, one stylesheet and one script. It can be served as is, for example with GitHub Pages from this folder.

| Page | What it covers |
|---|---|
| `index.html` | Home: the overview of everything that needs you, and doors to the other pages |
| `agents.html` | The harness for coding agents: sessions, workspace tools, review, approvals, limits |
| `chats.html` | One inbox for every chat app, and `@nook` writing replies |
| `assistant.html` | Ask Nook: screen context, plans, Nooks, memory, music and your day |
| `writing.html` | Autocomplete in every app, Flow dictation, Double Tap, call notes |
| `privacy.html` | Local-first brains, Only on this Mac, approvals and the audit log, what Nook never reads |
| `browser-extension-privacy.html` | The browser extension's privacy policy (linked from its Chrome Web Store listing) |
| `download.html` | Download, platforms, requirements, build from source |

## Editing

Edit the pages in `src/` and the shared pieces in `_partials/` (head, navigation, icons, footer), then build:

```sh
python3 site/build.py
```

This writes the finished pages next to `build.py`, plus what search engines and AI crawlers read: `sitemap.xml`, `robots.txt`, `llms.txt` and `site.webmanifest`. Every page gets a canonical URL, Open Graph and Twitter cards, and structured data (JSON-LD: the organization, the app, breadcrumbs, and an FAQ from the page's `.faq` block). The site address lives in `SITE` in `build.py`; a new page needs a name in its `LABELS`.

Each page has its own social card in `assets/og/`, made from its `<h1>` with headless Chrome. After changing a heading, run `python3 site/og.py` before `build.py`.

Links between pages are clean root paths (`/agents`, `/download`), as the hosting serves them, so preview with a server that does the same, for example `npx serve site`. `404.html` is the not-found page. `assets/nook.css` holds the design (the same tokens as `NookTheme`: one grey ramp, color only for state) and `assets/nook.js` the shared behaviour (reveal on scroll, `whenVisible`, copy buttons, Nook's eyes).

Describe Nook as the one calm place for everything that needs your attention; the notch is an optional extra, never the headline (see "What Nook Is" in `AGENTS.md`).
