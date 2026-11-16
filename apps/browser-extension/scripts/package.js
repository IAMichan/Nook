// `npm run package`: the zip to upload to the Chrome Web Store, in ../../.scratch/nook-extension-<version>.zip. Only
// what the browser loads goes in (no tests, sources of the composer or node_modules), and the manifest without its
// `key`: the key fixes the id of the unpacked extension Nook installs, and the Web Store refuses a key that is not the
// one of its own item.
import { execFileSync } from 'node:child_process';
import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

/** Everything the extension loads at run time. */
export const SHIPPED = ['manifest.json', 'background.js', 'sidepanel.html', 'sidepanel.css', 'sidepanel.js', '_locales', 'icons', 'lib', 'page', 'ui'];

const root = fileURLToPath(new URL('../', import.meta.url));
const manifest = JSON.parse(readFileSync(join(root, 'manifest.json'), 'utf8'));
const out = resolve(root, '../../.scratch');
const zip = join(out, `nook-extension-${manifest.version}.zip`);

const staging = mkdtempSync(join(tmpdir(), 'nook-extension-'));
try {
  for (const entry of SHIPPED) cpSync(join(root, entry), join(staging, entry), { recursive: true });
  delete manifest.key;
  writeFileSync(join(staging, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
  mkdirSync(out, { recursive: true });
  rmSync(zip, { force: true });
  execFileSync('zip', ['-qrX', zip, '.', '-x', '*.DS_Store'], { cwd: staging });
} finally {
  rmSync(staging, { recursive: true, force: true });
}
console.log(zip);
