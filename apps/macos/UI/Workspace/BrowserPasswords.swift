import Combine
import Foundation
import WebKit

/// The passwords Nook's browser saved, in Nook's Keychain vault (`SecretStore`, one item for all of Nook's secrets, so
/// there is no extra Keychain prompt). After you sign in to a site the browser asks to save the sign-in
/// (`BrowserStore.passwordQuestion`); the next time that site asks for it, the browser fills it in. Settings › Browser
/// lists them and removes them.
///
/// Only pages you opened yourself are filled: never one an agent opened, and never while an agent drives the browser,
/// so an agent cannot have a saved password typed into a page it reads.
@MainActor
final class BrowserPasswords: ObservableObject {
    static let shared = BrowserPasswords()

    private static let account = "browser.passwords"

    @Published private(set) var book = BrowserPasswordBook()
    private var loaded = false

    private init() {}

    /// Reads the vault the first time a password is needed, not at launch.
    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let text = SecretStore.read(Self.account), let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder.passwords.decode(BrowserPasswordBook.self, from: data) else { return }
        book = decoded
    }

    func credentials(for site: String) -> [BrowserCredential] {
        loadIfNeeded()
        return book.credentials(for: site)
    }

    func offer(site: String, username: String, password: String) -> BrowserPasswordBook.Offer {
        loadIfNeeded()
        return book.offer(site: site, username: username, password: password)
    }

    func save(site: String, username: String, password: String) {
        change { $0.save(BrowserCredential(site: site, username: username, password: password, lastUsed: Date())) }
    }

    func used(_ credential: BrowserCredential) {
        // Not worth a Keychain write each time: only when it was used another day.
        guard !Calendar.current.isDateInToday(credential.lastUsed) else { return }
        change { $0.used(credential.id) }
    }

    func remove(_ id: String) { change { $0.remove(id) } }
    func never(_ site: String) { change { $0.never(site) } }
    func allowAgain(_ site: String) { change { $0.allowAgain(site) } }

    private func change(_ edit: (inout BrowserPasswordBook) -> Void) {
        loadIfNeeded()
        var next = book
        edit(&next)
        guard next != book, let data = try? JSONEncoder.passwords.encode(next), let text = String(data: data, encoding: .utf8) else { return }
        let status = next.credentials.isEmpty && next.neverSites.isEmpty
            ? SecretStore.remove(Self.account) : SecretStore.write(text, account: Self.account)
        if status == errSecSuccess {
            book = next
        } else {
            ToastCenter.shared.error(tr("browser.passwords.saveFailed"))
        }
    }
}

/// A sign-in the browser asks you to save, held in memory only until you answer.
struct PasswordQuestion: Equatable {
    let site: String
    let username: String
    let password: String
    /// The site has this user name saved with another password: the question is whether to update it.
    let isUpdate: Bool
}

/// The page side of saved passwords: notices a sign-in being sent (the user name and password in the form) and fills
/// a saved one into a sign-in form. Runs in every frame, in a world of its own, so the page's scripts neither see nor
/// change it. Native code decides which sign-in belongs to a frame from the frame's own origin, never from what the
/// script says.
enum BrowserPasswordScript {
    static let handlerName = "nookPasswords"

    static let source = """
    (function () {
      if (window.__nookPasswords) { return; }
      window.__nookPasswords = true;
      var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName);
      if (!handler) { return; }
      function visible(el) {
        if (!el || el.disabled || el.readOnly) { return false; }
        var r = el.getBoundingClientRect();
        if (r.width < 2 || r.height < 2) { return false; }
        var s = window.getComputedStyle(el);
        return s.visibility !== 'hidden' && s.display !== 'none' && s.opacity !== '0';
      }
      function passwords(root) {
        return Array.prototype.filter.call((root || document).querySelectorAll('input[type=password]'), visible);
      }
      function isUserField(el) {
        var t = (el.type || 'text').toLowerCase();
        return (t === 'text' || t === 'email' || t === 'tel') && visible(el);
      }
      // The user name of a password field: the visible text field just before it in its form.
      function userField(pw) {
        var scope = pw.form || document;
        var marked = scope.querySelector('input[autocomplete~=username], input[autocomplete~=email]');
        if (marked && isUserField(marked)) { return marked; }
        var inputs = Array.prototype.slice.call(scope.querySelectorAll('input'));
        for (var i = inputs.indexOf(pw) - 1; i >= 0; i--) { if (isUserField(inputs[i])) { return inputs[i]; } }
        return null;
      }
      // A page that asks for the user name alone first (the password comes on the next page).
      function loneUserField(root) {
        var scope = root && root.querySelectorAll ? root : document;
        if (passwords(scope).length) { return null; }
        var marked = scope.querySelector('input[autocomplete~=username], input[autocomplete~=email], input[type=email]');
        return marked && isUserField(marked) && marked.value ? marked : null;
      }
      function setValue(el, value) {
        var setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
        setter.call(el, value);
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      }
      var lastSent = '';
      function send(root) {
        var fields = passwords(root).filter(function (f) { return f.value; });
        if (!fields.length) {
          var lone = loneUserField(root);
          if (lone) { handler.postMessage({ kind: 'username', username: lone.value }); }
          return;
        }
        var chosen = fields.filter(function (f) { return /new-password/.test(f.autocomplete || ''); })[0] || fields[0];
        var user = userField(chosen);
        var key = (user ? user.value : '') + '\\u001f' + chosen.value;
        if (key === lastSent) { return; }
        lastSent = key;
        handler.postMessage({ kind: 'submit', username: user ? user.value : '', password: chosen.value });
      }
      document.addEventListener('submit', function (e) { send(e.target); }, true);
      document.addEventListener('keydown', function (e) {
        var t = e.target;
        if (e.key === 'Enter' && t && t.tagName === 'INPUT') { send(t.form || document); }
      }, true);
      document.addEventListener('click', function (e) {
        var t = e.target;
        var button = t && t.closest ? t.closest('button, input[type=submit], [role=button]') : null;
        if (button) { send(button.form || document); }
      }, true);
      // Fill a saved sign-in into an empty sign-in form, once per form; a page that builds its form later is checked again.
      var asks = 0;
      function fill() {
        var empty = passwords().filter(function (f) { return !f.value && !f.__nookFilled && !/new-password/.test(f.autocomplete || ''); });
        if (!empty.length || asks >= 6) { return; }
        asks++;
        empty.forEach(function (f) { f.__nookFilled = true; });
        handler.postMessage({ kind: 'fill' }).then(function (reply) {
          if (!reply || !reply.password) { return; }
          empty.forEach(function (f) {
            if (f.value) { return; }
            setValue(f, reply.password);
            var user = userField(f);
            if (user && !user.value && reply.username) { setValue(user, reply.username); }
          });
        }, function () {});
      }
      var timer = null;
      function later() { if (timer) { clearTimeout(timer); } timer = setTimeout(fill, 250); }
      fill();
      new MutationObserver(later).observe(document.documentElement || document, { childList: true, subtree: true });
    })();
    """
}

/// Hands the password script's messages to the page without the web view holding on to the page.
final class PasswordMessages: NSObject, WKScriptMessageHandlerWithReply {
    weak var page: BrowserPage?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        let origin = message.frameInfo.securityOrigin
        let body = message.body as? [String: Any] ?? [:]
        MainActor.assumeIsolated {
            guard let site = BrowserPasswordBook.site(scheme: origin.protocol, host: origin.host), let page,
                  let store = page.store else {
                replyHandler(nil, nil)
                return
            }
            let username = (body["username"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            switch body["kind"] as? String {
            case "username":
                store.rememberUsername(username, site: site)
                replyHandler(nil, nil)
            case "submit":
                store.offerPassword(site: site, username: username, password: body["password"] as? String ?? "")
                replyHandler(nil, nil)
            case "fill":
                // Only for a page you opened, while no agent drives this browser.
                guard page.openedBy == nil, store.drivenBy == nil,
                      let saved = BrowserPasswords.shared.credentials(for: site).first else {
                    replyHandler(nil, nil)
                    return
                }
                BrowserPasswords.shared.used(saved)
                replyHandler(["username": saved.username, "password": saved.password], nil)
            default:
                replyHandler(nil, nil)
            }
        }
    }
}

private extension JSONEncoder {
    static var passwords: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }
}

private extension JSONDecoder {
    static var passwords: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
