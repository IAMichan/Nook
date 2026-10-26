#!/usr/bin/env node
// Renders a Nook video page (built on kit/) to an Instagram-ready MP4 with its calm score, plus a storyboard and,
// when asked, a cover image.
//
//   node render.mjs <video.html> --out .scratch/<name> [--name nook-reel] [--fps 30] [--cover cover.html]
//                   [--mood calm|warm|bright] [--bpm 84] [--no-groove] [--seed 7] [--chord 6] [--silent] [--keep-frames]
//
// Needs Node with Playwright (Chromium), ffmpeg, and python3 with numpy.
import { execFileSync, execSync } from 'node:child_process';
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const opt = (name, fallback) => { const i = args.indexOf('--' + name); return i >= 0 ? args[i + 1] : fallback; };
const flag = name => args.includes('--' + name);
const page = args.find(a => a.endsWith('.html') && args[args.indexOf(a) - 1] !== '--cover');
if (!page) { console.error('usage: node render.mjs <video.html> --out <dir> [--cover cover.html]'); process.exit(1); }

const out = path.resolve(opt('out', '.scratch/nook-video'));
const name = opt('name', path.basename(page, '.html'));
const fps = Number(opt('fps', 30));
const frames = path.join(out, '.frames');
fs.mkdirSync(frames, { recursive: true });

function loadPlaywright() {
  const require = createRequire(import.meta.url);
  try { return require('playwright'); } catch {}
  const root = execSync('npm root -g').toString().trim();
  return createRequire(path.join(root, 'noop.js'))('playwright');
}
const { chromium } = loadPlaywright();
const browser = await chromium.launch();
const tab = await browser.newPage({ viewport: { width: 1080, height: 1920 } });
await tab.goto(pathToFileURL(path.resolve(page)).href + '?still');
await tab.evaluate(() => document.fonts.ready);
const { duration, cues, music } = await tab.evaluate(() => ({ duration: window.DURATION, cues: window.CUES || [], music: window.MUSIC || {} }));
if (!duration) throw new Error('The page must call NV.boot({ duration, cues, render }).');

const count = Math.round(duration * fps);
console.log(`Rendering ${count} frames (${duration}s at ${fps} fps)…`);
for (let i = 0; i < count; i++) {
  await tab.evaluate(t => window.render(t), i / fps);
  await tab.screenshot({ path: path.join(frames, `f${String(i).padStart(5, '0')}.png`) });
  if (i % (fps * 5) === 0) process.stdout.write(`  ${(i / fps).toFixed(0)}s\n`);
}

const cover = opt('cover');
if (cover) {
  await tab.goto(pathToFileURL(path.resolve(cover)).href + '?still');
  await tab.evaluate(() => document.fonts.ready);
  await tab.evaluate(() => window.render && window.render(window.DURATION || 0));
  await tab.screenshot({ path: path.join(out, `${name}-cover.png`) });
  execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-i', path.join(out, `${name}-cover.png`), '-q:v', '2', path.join(out, `${name}-cover.jpg`)]);
}
await browser.close();

const mp4 = path.join(out, `${name}.mp4`);
const video = ['-framerate', String(fps), '-i', path.join(frames, 'f%05d.png')];
const encode = ['-c:v', 'libx264', '-profile:v', 'high', '-pix_fmt', 'yuv420p', '-crf', '18', '-preset', 'slow',
  '-r', String(fps), '-movflags', '+faststart'];
if (flag('silent')) {
  // A silent track still: Instagram treats a video without audio differently, and music can be added in the app.
  execFileSync('ffmpeg', ['-y', '-loglevel', 'error', ...video, '-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo',
    '-shortest', ...encode, '-c:a', 'aac', '-b:a', '192k', mp4]);
} else {
  const wav = path.join(out, `${name}-score.wav`);
  console.log('Composing the score…');
  // The page's NV.boot({ music }) sets the score; flags on the command line win.
  const m = { mood: 'calm', seed: 7, chord: 6, ...music };
  const score = ['--duration', String(duration), '--cues', JSON.stringify(cues), '--mood', opt('mood', m.mood),
    '--seed', String(opt('seed', m.seed)), '--chord', String(opt('chord', m.chord)), '--out', wav];
  const bpm = opt('bpm', m.bpm);
  if (bpm && !flag('no-groove')) {
    score.push('--bpm', String(bpm));
    if (m.drumsFrom != null) score.push('--drums-from', String(m.drumsFrom));
    if (m.drumsUntil != null) score.push('--drums-until', String(m.drumsUntil));
  }
  execFileSync('python3', [path.join(here, 'music.py'), ...score]);
  // Calm, not quiet: -16 LUFS sits just under what Instagram plays back, with 2 dB of true-peak headroom.
  execFileSync('ffmpeg', ['-y', '-loglevel', 'error', ...video, '-i', wav, ...encode,
    '-af', 'loudnorm=I=-16:TP=-2:LRA=7', '-c:a', 'aac', '-b:a', '192k', '-ar', '48000', '-shortest', mp4]);
}

// Storyboard: six evenly spaced frames side by side, to check the whole video at a glance.
const step = Math.max(1, Math.floor(count / 6));
execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-framerate', String(fps), '-i', path.join(frames, 'f%05d.png'),
  '-vf', `select='eq(mod(n+${Math.floor(step / 2)}\\,${step})\\,0)',scale=360:-1,tile=6x1:padding=10:color=0x333333`,
  '-frames:v', '1', '-update', '1', path.join(out, `${name}-storyboard.png`)]);

if (!flag('keep-frames')) fs.rmSync(frames, { recursive: true, force: true });
console.log(`Done: ${mp4}`);
