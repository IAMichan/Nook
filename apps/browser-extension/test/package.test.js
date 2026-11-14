// The extension as a whole: its manifest, its id (the one Nook's host lets in), and its texts in Nook's five languages.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync, readdirSync } from 'node:fs';
import { HOST_NAME, PROTOCOL_VERSION } from '../lib/core.js';

const root = new URL('../', import.meta.url);
const read = (path) => readFileSync(new URL(path, root), 'utf8');
const manifest = JSON.parse(read('manifest.json'));
const swiftHost = read('../macos/Services/BrowserExtension/BrowserExtensionHost.swift');
const swiftHub = read('../macos/Services/BrowserExtension/BrowserExtensionHub.swift');

test('the key in the manifest gives the id Nook\'s host allows', () => {
  const digest = createHash('sha256').update(Buffer.from(manifest.key, 'base64')).digest('hex').slice(0, 32);
  const id = [...digest].map((c) => String.fromCharCode(97 + parseInt(c, 16))).join('');
  assert.match(swiftHost, new RegExp(`static let extensionID = "${id}"`));
});

test('the extension and Nook agree on the host and the protocol', () => {
  assert.ok(swiftHost.includes(`static let name = "${HOST_NAME}"`), HOST_NAME);
  assert.match(swiftHub, new RegExp(`static let protocolVersion = ${PROTOCOL_VERSION}\\b`));
});

test('it asks only for what it uses', () => {
  assert.equal(manifest.manifest_version, 3);
  assert.deepEqual([...manifest.permissions].sort(), ['alarms', 'nativeMessaging', 'scripting', 'sidePanel', 'storage', 'tabGroups', 'tabs']);
  assert.ok(!manifest.permissions.includes('debugger'), 'no debugger: Nook never takes over the browser');
  assert.ok(!manifest.content_scripts, 'nothing runs on pages until Nook is asked');
});

test('every text is there in all five languages', () => {
  const languages = readdirSync(new URL('_locales/', root));
  assert.deepEqual(languages.sort(), ['de', 'en', 'es', 'fr', 'nl']);
  const english = JSON.parse(read('_locales/en/messages.json'));
  for (const language of languages) {
    const messages = JSON.parse(read(`_locales/${language}/messages.json`));
    assert.deepEqual(Object.keys(messages).sort(), Object.keys(english).sort(), language);
    for (const [key, { message }] of Object.entries(messages)) {
      assert.equal((message.match(/\$\d/g) || []).join(), (english[key].message.match(/\$\d/g) || []).join(), `${language}.${key}`);
    }
  }
  const used = new Set();
  for (const file of ['sidepanel.html', 'sidepanel.js', 'page/presence.js', 'manifest.json']) {
    const text = read(file);
    for (const match of text.matchAll(/data-i18n(?:-placeholder)?="(\w+)"|\bt\('(\w+)'|getMessage\('(\w+)'|__MSG_(\w+)__/g)) {
      used.add(match[1] || match[2] || match[3] || match[4]);
    }
  }
  for (const key of used) assert.ok(english[key], `missing text ${key}`);
});
