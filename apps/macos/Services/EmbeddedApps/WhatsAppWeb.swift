import Foundation

// whatsapp_send without a linked phone: when WhatsApp Web is open next to the chat ("@open whatsapp web"), Nook sends
// the approved message through it, the way the user would: search the chat, open it, type the text, press send. This is
// the part without WebKit (the script that runs in the page and what its answer means), so it can be tested anywhere;
// `EmbeddedAppStore.sendWhatsApp` runs it in the web view.

enum WhatsAppWeb {
    /// The longest message Nook types into WhatsApp Web in one go.
    static let maxText = 4_000

    static func isWhatsAppWeb(_ url: URL?) -> Bool {
        url?.host?.lowercased() == "web.whatsapp.com"
    }

    /// How a send through WhatsApp Web ended.
    enum Outcome: Equatable {
        /// Sent, in the chat with this exact name.
        case sent(String)
        /// WhatsApp Web shows its QR code or is still loading: there is no chat list yet.
        case signedOut
        /// No chat has this name.
        case notFound
        /// Several chats match; their names, so the user can say which one.
        case ambiguous([String])
        /// The chat already holds text the user typed and did not send; Nook leaves it alone.
        case draft(String)
        /// The text is typed in the chat, but pressing send did not clear it.
        case notSent(String)
        /// The page did not look like WhatsApp Web expects at this step (search, chat, composer, text).
        case failed(String)
    }

    /// The script's answer (a dictionary from the page) as an outcome.
    static func outcome(_ raw: Any?) -> Outcome {
        guard let result = raw as? [String: Any], let status = result["status"] as? String else { return .failed("answer") }
        let chat = (result["chat"] as? String) ?? ""
        switch status {
        case "sent": return .sent(chat)
        case "signedOut": return .signedOut
        case "notFound": return .notFound
        case "ambiguous": return .ambiguous(((result["candidates"] as? [Any]) ?? []).compactMap { $0 as? String })
        case "draft": return .draft(chat)
        case "notSent": return .notSent(chat)
        default: return .failed((result["step"] as? String) ?? status)
        }
    }

    /// The body of an async function run in the page with `name` (the chat) and `text` (the message) as arguments. It
    /// sends only to a chat whose name matches (exactly first, else the one chat that starts with or contains it), only
    /// once the chat's own header shows that name, only into an empty composer, and only when the composer then holds
    /// exactly the approved text. Elements are found by structure and icons, not by labels, so the page's language does
    /// not matter.
    static let sendScript = #"""
    const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
    const norm = value => (value || '').normalize('NFC').toLowerCase().replace(/\s+/g, ' ').trim();
    const squash = value => (value || '').normalize('NFC').replace(/\s+/g, '');
    const until = async (find, ms) => {
      const end = Date.now() + ms;
      for (;;) {
        const found = find();
        if (found) return found;
        if (Date.now() > end) return null;
        await sleep(150);
      }
    };
    // What an element shows as text, with emoji that are drawn as images.
    const plain = node => {
      if (node.nodeType === 3) return node.nodeValue;
      if (node.nodeType !== 1) return '';
      if (node.tagName === 'IMG') return node.getAttribute('alt') || '';
      let text = '';
      for (const child of node.childNodes) text += plain(child);
      return text;
    };
    const press = element => {
      for (const type of ['mousedown', 'mouseup', 'click']) {
        element.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, view: window }));
      }
    };
    const fill = (element, value) => {
      element.focus();
      if (element.isContentEditable || element.getAttribute('contenteditable') === 'true') {
        document.execCommand('selectAll', false, null);
        if (value) document.execCommand('insertText', false, value);
        else document.execCommand('delete', false, null);
      } else {
        const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(element), 'value').set;
        setter.call(element, value);
        element.dispatchEvent(new Event('input', { bubbles: true }));
      }
    };
    const key = (element, shift) => {
      for (const type of ['keydown', 'keyup']) {
        element.dispatchEvent(new KeyboardEvent(type, {
          key: 'Enter', code: 'Enter', keyCode: 13, which: 13, shiftKey: shift, bubbles: true, cancelable: true
        }));
      }
    };

    const side = await until(() => document.querySelector('#side'), 3000);
    if (!side) return { status: 'signedOut' };
    const search = side.querySelector('[contenteditable="true"], input[type="text"], input[type="search"], input:not([type])');
    if (!search) return { status: 'failed', step: 'search' };
    const wanted = norm(name);
    if (!wanted) return { status: 'notFound' };
    fill(search, name);
    await sleep(900);

    // Every chat in the list (or in the search results) with its name: the first titled text in its row.
    const chats = () => {
      const list = document.querySelector('#pane-side') || side;
      const seen = new Set();
      const found = [];
      for (const row of list.querySelectorAll('[role="listitem"], [role="row"]')) {
        const title = row.querySelector('span[title]');
        if (!title || seen.has(title)) continue;
        seen.add(title);
        const label = (title.getAttribute('title') || '').trim();
        if (label) found.push({ title, label });
      }
      return found;
    };
    // The best matching chats: exact names first, then names that start with, then names that contain what was asked.
    const best = () => {
      const all = chats();
      for (const test of [label => norm(label) === wanted, label => norm(label).startsWith(wanted), label => norm(label).includes(wanted)]) {
        const matches = all.filter(chat => test(chat.label));
        if (matches.length) return { matches };
      }
      return null;
    };
    let match = null;
    const end = Date.now() + 5000;
    while (Date.now() < end) {
      match = best();
      if (match && norm(match.matches[0].label) === wanted) break;
      await sleep(250);
    }
    if (!match) return { status: 'notFound' };
    // The same chat listed twice (under chats and under messages) is one chat.
    const names = [...new Set(match.matches.map(chat => chat.label))];
    if (names.length > 1) return { status: 'ambiguous', candidates: names.slice(0, 8) };
    const chat = match.matches[0];
    press(chat.title);

    const header = await until(() => {
      const element = document.querySelector('#main header');
      return element && norm(plain(element)).includes(norm(chat.label)) ? element : null;
    }, 5000);
    if (!header) return { status: 'failed', step: 'chat' };
    const composer = await until(() => document.querySelector('#main footer [contenteditable="true"]'), 3000);
    if (!composer) return { status: 'failed', step: 'composer' };
    if (squash(plain(composer))) return { status: 'draft', chat: chat.label };

    composer.focus();
    const lines = text.split('\n');
    lines.forEach((line, index) => {
      if (index > 0) key(composer, true);
      if (line) document.execCommand('insertText', false, line);
    });
    await sleep(300);
    if (squash(plain(composer)) !== squash(text)) {
      fill(composer, '');
      return { status: 'failed', step: 'text' };
    }

    const icon = await until(() => document.querySelector('#main footer [data-icon="send"], #main footer [data-icon="wds-ic-send-filled"], #main footer [data-icon*="send"]'), 2000);
    const button = icon && (icon.closest('button, [role="button"]') || icon);
    if (button) press(button); else key(composer, false);
    const cleared = await until(() => !squash(plain(composer)), 4000);
    if (!cleared) return { status: 'notSent', chat: chat.label };
    return { status: 'sent', chat: chat.label };
    """#
}
