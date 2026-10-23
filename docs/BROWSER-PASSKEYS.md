# Passkeys in Nook's browser

Nook's browser (Agents › Browser, and the small follow-along window) is a `WKWebView`. macOS only lets a web view use
passkeys and security keys for any website when the app is signed with Apple's **web browser public key credential**
entitlement (`com.apple.developer.web-browser.public-key-credential`). Without it, sites such as Google ask for
Bluetooth and a nearby phone, and the sign-in stops there.

With the entitlement the system's passkeys are used, and only builds signed with it get them. A Chromium-based browser
needs its own JavaScript bridge to AuthenticationServices because Chromium does not hand WebAuthn to macOS. WebKit does
that itself once the entitlement is present, so Nook needs no bridge.

## How Nook behaves

- **Signed with the entitlement:** WebKit handles WebAuthn like Safari does: passkeys from iCloud Keychain, a phone
  nearby (over Bluetooth or a QR code) and security keys. Nook checks the entitlement at launch
  (`BrowserStore.hasPasskeyEntitlement`).
- **Without it (default):** Nook hides passkeys from pages, so sites offer a password, a code or the phone prompt
  instead of the Bluetooth dead end. The **Open in your own browser** button hands the page to the default browser for
  anything that still needs one.

## Enabling it

1. The Account Holder of the Apple Developer team requests the entitlement from Apple (the macOS web browser form).
2. Once Apple grants it, add it to the app's entitlements in `apps/macos/project.yml`:

   ```yaml
   entitlements:
     path: App/Nook.entitlements
     properties:
       com.apple.developer.web-browser.public-key-credential: true
   ```

3. Run `xcodegen` in `apps/macos` and build with that team's signing identity. Builds signed ad hoc or by a team
   without the grant fail to sign with this key, so leave it out for those.
