---
name: nook-video
description: Make a short video about Nook (an Instagram Reel, TikTok, YouTube Short, or a clip for the README or a release) in Nook's own look: catchy but calm, with Nook as the main character, cuts on the beat, a soft generated lo-fi groove and sound cues, plus a cover image and a caption. Use when the user asks for a video, reel, promo, teaser, social post with motion, release clip, or "something for Instagram" about Nook or one of its features.
---

# Making a Nook video

A Nook video looks like Nook and feels like Nook, and it is fun to watch: Nook itself (the orb) as the main
character, a hook on the very first frame, the real notch UI on a near-black canvas, words that land on the beat, and a
soft lo-fi groove under it. Catchy, never loud: no flashes, no hard hits, nothing that shouts. Calm by design, like
the app (see the comment on `enum NookTheme` in `apps/macos/NotchUI/Theme/NookTheme.swift`).

Reply in the user's language. Everything inside the video and the files in this skill is English unless the user asks
for another language; Nook speaks English, Dutch, German, French and Spanish, so those are the languages to offer.

## What's here

| Path | What it is |
|---|---|
| `kit/nook-video.css` | NookTheme's tokens for video (colors, radii and spacing at 2.6×), the orb, the notch panel, rows, state chips, composer, type, cards, steps, the end card, safe zones |
| `kit/nook-video.js` | `NV`: the frame clock (`NV.boot`) and beat grid (`NV.tempo`), motion (`fade`, `stagger`, `settle`, `pop`, `ease`, `swapText`, `breathe`), kinetic type (`words`, `cycle`, `type`), the orb (`NV.orb` breathes, blinks, looks around and winks like `NookOrb.swift`), Nook's celebration sparks (`NV.sparks`), and every app state with its color (`NV.STATES`, `NV.state`) |
| `scripts/render.mjs` | Renders a page frame by frame with Playwright, composes the score, mixes and encodes the MP4, renders the cover, makes a storyboard |
| `scripts/music.py` | The score: pads, soft bass, a lo-fi groove (plucked arpeggio, round kick, snap, a whisper of hi-hat) and sound cues, generated from scratch (numpy only), so it is free to use anywhere |
| `examples/contributor-reel.html`, `examples/contributor-cover.html` | A complete 25 s Reel on an 80 BPM grid with a cold open, and its cover: copy these to start |
| `examples/readme-clip.html` | The 1600×900 README clip (`docs/assets/nook-demo.mp4` and `.gif`): the release banner's layout, with the notch's tabs changing per scene |

Needs Node with Playwright (Chromium), `ffmpeg`, and `python3` with `numpy`. On a Mac:
`brew install ffmpeg node && npm i -g playwright && npx playwright install chromium && pip3 install numpy`.

## Steps

1. **Pin down the message.** One goal per video (recruit contributors, show a feature, announce a release). Read what
   is true before writing a word: `README.md`, `CONTRIBUTING.md`, `docs/ROADMAP.md`, the feature's doc in `docs/`, and
   the strings in `apps/macos/Core/I18n*.swift` so labels in the video match the app's own words. Never show a feature,
   number, platform or claim that the repository does not back up.
2. **Write the script on the beat grid.** Use about 80 BPM (a bar is 3 s) and give every scene one or two bars: a
   one-bar cold open (see "The first two seconds"), then one idea per scene, and an end card that holds at least 4 s. One line on screen
   per scene (headline ≤ 6 words), plus what the notch or Nook does in it. 20–30 s in total. Then check the reading
   time of every line (see "Fast in, long enough to read"). Mark the moments that get a
   sound cue (the drop when the notch opens, cards arriving, a state turning to done or merged, the end card).
3. **Build the page** in `.scratch/<name>/` (git-ignored; see AGENTS.md section 5) by copying
   `examples/contributor-reel.html`, and point its `<link>` and `<script>` at this skill's `kit/` with a relative path
   (from `.scratch/<name>/`: `../../.claude/skills/nook-video/kit/…`). A page is `render(t)`, which draws the frame at
   `t` seconds, and one call `NV.boot({ duration, cues, music, render })`; `music` sets the score
   (`{ bpm, drumsFrom, drumsUntil, mood }`). Time everything with `NV.tempo(bpm)` (`BAR(n)`, `B(n)`) so pictures and
   music stay locked together. Open it with `?t=12.5` for a still, `?safe=1` to
   see Instagram's safe zones.
4. **Check stills before rendering the whole video.** Take stills at the middle of every scene and at each transition,
   look at them, and fix overflow, wrapping, safe-zone collisions and color meaning first. A full render takes about
   2 minutes for 25 s.
5. **Render:**
   ```sh
   node .claude/skills/nook-video/scripts/render.mjs .scratch/<name>/video.html \
     --cover .scratch/<name>/cover.html --out .scratch/<name> --name <name> [--mood calm|warm|bright] [--seed 7] [--no-groove]
   ```
   This writes `<name>.mp4`, `<name>-score.wav`, `<name>-storyboard.png` and `<name>-cover.png/.jpg`. Use `--silent`
   only when the user wants to add music in Instagram itself.
6. **Check the result**: look at the storyboard, verify with `ffprobe` that the MP4 has an AAC audio stream and the
   expected length, and that loudness came out near -16 LUFS
   (`ffmpeg -i <name>.mp4 -af ebur128 -f null - 2>&1 | grep -A3 Summary`). You can't hear it; say so, and check the
   spectrum (`showspectrumpic`) if you changed `music.py`.
7. **Write the caption** to `.scratch/<name>/caption.md` (see below).
8. **Hand it over** with `SendUserFile` (`display: "render"`): the MP4, the storyboard, the cover and the caption, as
   soon as they are ready. Never commit anything from `.scratch/`.

## Nook's look

Everything comes from `NookTheme`; the kit already has it. Do not add colors, fonts or radii of your own.

- **Canvas and surfaces:** one neutral grey ramp, no blue cast: canvas `#0A0A0A`, the notch `#000`, rows and cards
  `#171717` (graphite), chips and selected tabs `#1F1F1F` (smoke). Regions read by their fill; strokes are rare and only
  a shade lighter than what they edge.
- **Text:** `#F5F5F5` (paper) for what matters, `#999999` for supporting lines, `#6E6E6E` for the quiet half of a
  headline ("No Mac? <muted>No problem.</muted>").
- **Type:** the system font (SF Pro on a Mac, Inter as the stand-in elsewhere); headlines bold with tight tracking, the
  rest regular. Mono only for code, commands and branch names.
- **The notch panel** is the hero: the real tabs (Nook, Chat, Agents, Shelf, Music), rows with a state dot, title,
  subtitle, time and chip, and the composer ("Ask Nook anything…"). Show what Nook actually does, with believable
  content (agents finishing, chats waiting, pull requests moving), never a made-up screen.
- **Nook, the orb:** a round light with two bar eyes, lit like a ball. It breathes (±5 % every 3.4 s) and blinks at
  irregular moments, exactly as `NookOrb.swift` does; `NV.orb` handles both. Its color and eyes follow its mood:
  `rest` (iris), `done`/`proud`/`celebrate` (mint, happy ^ ^ eyes), `waiting`/`remind`/`cozy` (amber), `worry`
  (coral), `caring` (soft coral), `breathe`/`sleepy` (eyes shut). Use the orb as the logo, and let its mood react to
  the story (proud for a moment when something is merged).
- **Safe zones (Reels):** keep text and the notch out of the top 220 px, the bottom 420 px (y > 1500), and the right
  120 px where Instagram draws its buttons. A cover is cropped to 3:4 in the profile grid (y 240–1680): put everything
  that matters inside it.

### State colors: one meaning each

The app gives every color exactly one meaning, and so does a video. Use a state color only for a state (a dot, a chip,
the orb), never to decorate a card, a tag or a headline; decoration stays grey (`.tag`). `NV.state(el, 'merged',
'Merged')` sets the right color from the state's name; `NV.STATES` lists them all:

| Color | Means | States in the app |
|---|---|---|
| iris `#F4F3F7` | Nook itself, busy, info | running, busy, thinking, connecting, info, note; the orb at rest |
| mint `#5ED6A6` | good, done, going | done, open (PR), passing checks, approved, connected, working, success, listening, added, allowed |
| amber `#F2B866` | waits on you | waiting, needs you, changes requested, expired, warning, caution, blocked, behind, stacked PR, approval pending |
| coral `#EF7B73` | broken | error, failed, failing checks, conflict, unreachable, denied, deleted |
| soft coral `#F29A92` | closed, gently failed | closed PR, a failed scheduled run, caring |
| violet `#AE94F2` | merged | merged pull requests only |
| blue `#8FB3F0` | links | links, read receipts, modified files |
| grey `#999999` | nothing to do yet | draft, checks running, commented, review required |
| music `#F0936A` | music | the Music tab only |

Chips are the state color at 14 % on its own tint, as in the app. Words on chips are the app's own (Done, Waiting,
Open, Merged, Approved, Commented, Draft, Failed); check `I18n.swift` for the exact word.

## Catchy, and still calm

People decide in the first second whether to keep watching. Make that second count, then keep a rhythm. The app
animates with springs and never jerks; a video does the same, on the beat.

- **The first two seconds decide everything.** People scroll on within two seconds, so the video starts in the middle
  of the action (a cold open):
  - **Frame one already says something:** a bold line is fully on screen at `t = 0`, a statement that makes people
    curious ("This lives in your notch."). Never a fade from black, a logo splash, a title card, or an empty frame.
  - **The product moves at once:** the notch is opening on frame one, and within two seconds things land in it on the
    beat (an agent done, one waiting, a pull request merged) and Nook celebrates with sparks.
  - **The music is already going:** drums from the first frame (`drumsFrom: 0`), no fade-in, a cue on `t = 0`.
  - Tried and rejected: opening on the orb slowly looking around with "Psst. Got a minute?" lost viewers within two
    seconds. Character moments belong after the hook, not before it.
- **Then the story:** the reason to care (it's open source), who it needs, how easy it is, and the call to action; one
  idea per scene, a new scene about every 3 s.
- **Fast in, long enough to read.** Catchy comes from quick, on-beat arrivals; readable comes from how long a line
  then stays. Keep the two apart:
  - Arrivals are quick: about 0.6 s (`SNAP = { dur: 0.6 }`), words 0.12–0.2 s apart, cards one per beat, tags a
    quarter second apart. Exits 0.3–0.5 s.
  - A line stays fully readable for at least 1.2 s + 0.3 s per word, counted from the moment its last word has landed
    (not from when it starts) until its exit starts. A one-word swap (`NV.cycle`) needs about 1 s; give it two beats.
  - Never reveal a line one word per beat: the end of the sentence arrives just as it leaves.
  - Check this with stills just before each exit: every word must be sharp.
  - Too fast (84 BPM, a change on every beat, words a beat apart) and too slow (72 BPM, 1 s arrivals, two beats
    between everything) were both tried and rejected; 80 BPM with quick arrivals and this reading rule is the balance.
- **Rhythm:** something lands on most beats, but only one thing at a time. A big word swaps every two beats (at most
  4–5 words: "Developers. Translators. Testers. You."), and the last word of a series stays longest.
- **Kinetic type:** headlines arrive word by word out of a soft blur (`NV.words`), short and big (≥ 96 px). The quiet
  half of a line in tertiary grey ("It's open <muted>source.</muted>").
- **Nook acts:** the orb's mood carries the emotion: `celebrate` with sparks (`NV.sparks`) when something is merged,
  happy eyes for done, a wink (`wink`) on the end card. Keep the orb in most scenes; it is the brand.
- **Show the product moving:** states change in the notch one beat apart (checks running → passed → approved →
  merged), each with a soft chip pulse. Real states, real words, real colors.
- **Arrivals:** `NV.pop` (NookTheme.open's small overshoot) for things that pop in; `NV.settle` (no bounce) for things
  that move; `NV.fade` for things that leave. Nothing shakes, spins, flashes, strobes or zooms fast; no more than 3
  changes in brightness a second.
- **Life in between:** the background light breathes (`NV.breathe`) and lifts softly on each kick, the orb breathes
  and blinks. Never an empty black frame between scenes.
- **The end card** holds ≥ 4 s: the orb, a "Build Nook with us." style line, then the URL, tags and "Link in bio"
  about a beat apart, and a wink.
- For a quiet piece (a release note, a thank-you), drop the groove (`--no-groove`, no `bpm`), slow the fades to 1 s and
  give each scene 4–5 s: the same kit, the calm end of the dial.

## Sound: a soft groove

`render.mjs` composes the score with `music.py` and mixes it to -16 LUFS with 2 dB of true-peak headroom.

- **Groove (with `bpm`, about 80):** open chords (major sevenths and ninths), one per bar, a soft plucked arpeggio from
  the first second, and from the first frame (or a later drop) a round kick on 1 and 3, a quiet finger snap on 2
  and 4 and a whisper of swung hi-hat (it may start mid-bar, on the drop); the pads dip softly on each kick so it all breathes. Lo-fi, warm, unhurried,
  nothing bright or hard.
  Stop the drums when the end card arrives (`drumsUntil`) and let the chords and the `end` bell ring out.
- **Ambient (no `bpm`):** the same chords swelling slowly, a soft bass and sparse bells, no drums: for the quiet pieces.
- **Moods:** `calm` (default), `warm` (a little darker, for evening or reflective pieces) or `bright` (for launches and
  good news); `--seed` picks another variation.
- **Cues** (`cues: [{ t, sound, gain }]` in `NV.boot`): `open` (an airy swell and a low bell, for the notch opening),
  `chime` (two soft bells, for something new appearing), `done` (a rising pair, for done or approved), `merge` (three
  rising notes, for merged), `end` (a low warm bell, for the end card), `tick` (barely there). They are tuned to the
  chord that is sounding. A cue lands on the frame its change becomes visible; use `tick` for cards arriving and keep
  the bigger cues (`open`, `done`, `merge`, `end`) for the 4–5 moments that matter.
- **Sound off:** most people watch muted. The text on screen carries the whole message; music only sets the mood.
- The score is generated, so it is free of rights; do not add music from elsewhere unless the user supplies it and
  owns the rights.

## Copy: Nook's voice

Plain, warm, and concrete, the way the README and commit messages read.

- Short sentences in the second person ("Pick what fits you.", "That could be you."). One idea per scene.
- Say what Nook does in its own terms: "Your AI assistant and coding-agent command center, in the notch." Use the names
  the app uses (Chats tab, Agents, Shelf, Settings › Chats, Nook Companion).
- No hype: no "revolutionary", "game-changing", "unleash", "supercharge", no stacked exclamation marks, no emoji in the
  video itself (a few in the caption are fine).
- Only claims the repository supports: macOS 15 or newer on Apple Silicon, local-first, open source, the platforms and
  languages it really has. When unsure, leave it out.
- Credit people and other projects correctly, and never imitate another brand's look.

## Formats

| Use | Size | Notes |
|---|---|---|
| Reel / TikTok / Short | 1080×1920, 30 fps | H.264 High, yuv420p, AAC 48 kHz 192 kbps, `+faststart`; 15–30 s |
| Reel cover | 1080×1920 | Key content inside 1080×1440 centered (the grid crop) |
| Feed post | 1080×1350 | Set `html, body` to that size and drop the menu bar; same rules |
| README or release clip | 1600×900 or the banner's 1800×620 | Render with `--size 1600x900`; use `docs/assets/release-banner.png` as the reference layout. GitHub does not play a video from the repository inline, so embed a GIF (`fps=15`, 960 px wide, under 5 MB) that links to the MP4 |

## Caption

Write it to `.scratch/<name>/caption.md`, English first and the user's language below it if that differs.

- A first line that works alone (it is all people see before "more"), then 3–6 short lines or a small list, then one
  call to action.
- Links are not clickable in Instagram captions: write "link in bio" and give the URL in plain text
  (`github.com/IAMichan/nook`), and tell the user to put the link in their bio or a link sticker.
- 8–15 relevant hashtags at the end (#opensource #macos #swift …), no unrelated trending tags.
- Remind the user to add alt text in Instagram's advanced settings; offer one sentence for it.

## Checklist before handing over

- [ ] Every claim and label is backed by the repository; labels use the app's own words.
- [ ] State colors keep their one meaning; nothing decorative is colored.
- [ ] Nothing in the safe zones; nothing wraps or clips (check the stills at every scene).
- [ ] Frame one has a bold line and motion, the music is playing, and the product shows something within 2 s.
- [ ] Arrivals are quick and on the beat, and the orb acts.
- [ ] Every line passes the reading rule (1.2 s + 0.3 s per word after its last word lands); all words sharp before each exit.
- [ ] Motion is soft: no shakes, flashes, hard zooms or empty frames; every headline is up long enough to read twice.
- [ ] The MP4 has audio, the right length, loudness near -16 LUFS; cues land on their moments.
- [ ] Cover, storyboard and caption are made and sent with `SendUserFile`; nothing from `.scratch/` is committed.
