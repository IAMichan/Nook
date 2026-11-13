# Nook website

A static site with no dependencies: plain HTML, one stylesheet and one script. It is published to GitHub Pages by `.github/workflows/site.yml` whenever `site/` changes on main.

| Page | What it covers |
|---|---|
| `index.html` | Home: the overview of everything that needs you, and doors to the other pages |
| `agents.html` | The harness for coding agents: sessions, workspace tools, review, approvals, limits |
| `chats.html` | One inbox for every chat app, and `@nook` writing replies |
| `assistant.html` | Ask Nook: screen context, plans, Nooks, memory, music and your day |
| `writing.html` | Autocomplete in every app, Flow dictation, Double Tap, call notes |
| `privacy.html` | Local-first brains, Only on this Mac, approvals and the audit log, what Nook never reads |
| `download.html` | Download, platforms, requirements, build from source |

## Editing

Edit the pages in `src/` and the shared pieces in `_partials/` (head, navigation, icons, footer), then build:

```sh
python3 site/build.py
```

This writes the finished pages next to `build.py`. `assets/nook.css` holds the design (the same tokens as `NookTheme`: one grey ramp, color only for state) and `assets/nook.js` the shared behaviour (reveal on scroll, `whenVisible`, copy buttons, Nook's eyes).

Describe Nook as the one calm place for everything that needs your attention; the notch is an optional extra, never the headline (see "What Nook Is" in `AGENTS.md`).
