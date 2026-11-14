# Android companion: what is left

The Android app is the same companion as the iPhone app (see [COMPANION.md](COMPANION.md), *Android*). This page lists
what still has to happen before the two work alike everywhere: first what only the owner of the project can do (accounts,
keys, a real phone), then what is still to be built.

## For the owner

These need an account, a key or a device, so they cannot be done from a cloud session.

### 1. A Firebase project for push notifications

Android has no APNs: a notification that reaches a phone whose app is closed goes through Firebase Cloud Messaging (FCM).

1. Create a project in the [Firebase console](https://console.firebase.google.com) (any name, for example "Nook").
2. Add an **Android app** to it with the package name `nl.imdigital.nook` (the `identifier` in
   `apps/tauri/src-tauri/tauri.conf.json`).
3. Download **`google-services.json`** and put it in `apps/tauri/src-tauri/gen/android/app/`. This file is not a secret:
   it only names the project, and it may be committed.
4. In *Project settings › Service accounts*, create a **private key** (a JSON file). This one **is** a secret: never commit
   it and never paste it into a chat. It goes into the relay as a secret (step 2).

### 2. The key in Nook's relay

Pushes to iPhones already go through the relay worker (`apps/relay`, see `apps/relay/README.md`, *Push through the
relay*), which holds the APNs key. Android pushes will go the same way.

1. Add the service account JSON from step 1.4 to the worker as a secret, for example
   `npx wrangler secret put FCM_SERVICE_ACCOUNT` in `apps/relay`, and paste the file's contents when asked.
2. Deploy the worker as you do now.

Until this is done the Android app keeps its current behaviour: notifications only while the app runs.

### 3. Try it on a real Android phone

Nothing on Android has run on a real device yet. The APK is built by CI (job **Android** in `.github/workflows/tauri.yml`)
on every push to `main`; it is unsigned, so allow installing from unknown sources.

Check, and report what fails:

- [ ] Pair by scanning the QR code from Nook › Settings › iPhone companion on the Mac (camera permission asked).
- [ ] After pairing the app opens on the Nook tab; the tabs, counts and the orb's menu work.
- [ ] A session's conversation follows live while the app is open; it catches up after the phone sleeps.
- [ ] Allow / Deny, deny with a reason, answer a question, Steer now and After this turn.
- [ ] New session, with Plan first, a model and a worktree.
- [ ] Changes: pick lines, comment, the comment lands in the message.
- [ ] Pull requests: list, detail, files, a line comment, a review, Merge, Work on this.
- [ ] A picture from the gallery goes with a message (the picker opens, the picture shows on the Mac).
- [ ] Dictation: the microphone permission is asked once, words land in the field, the language menu (touch and hold).
- [ ] Chats: a WhatsApp chat can be answered, also as a reply to a message; other chats say how to answer them.
- [ ] The back button closes menus, sheets and screens before leaving the app.
- [ ] Share text from another app to Nook: it offers New session, Ask Nook or a session.
- [ ] Settings › Nook on this phone opens Nook's own app; the phone icon in its tab bar goes back to the companion.

### 4. A signing key (when you want to hand the APK out)

CI builds an unsigned APK. To publish it (Play Store or a download), create an upload key once (`keytool -genkey …`)
and add it to the repository's GitHub secrets; then the Android job can sign the release build. Not needed for testing.

## Still to build

What the iPhone app does that the Android companion does not yet. Each follows the iPhone's code and copy.

- **Push notifications through FCM**, once the owner's steps 1 and 2 are done: the phone registers its FCM token
  (`register` with `item` `fcm`), the Mac and Nook on Windows and Linux send through the relay, notifications get Allow,
  Deny and Reply as on the iPhone, and a quiet ongoing notification stands in for Live Activities.
- **Files and terminals** of a session (`files`, `terminals`, `fileData` previews).
- **Older sessions** and the Mac's search through all of them (`history`).
- **Several Macs** on one phone (`CompanionPairings`).
- **Away from home**: other routes and the relay (`routes`, `relay`).
- **The outbox**: messages that wait while the Mac is away, sent again with the same id (`retry`).
- **Compression** of large answers (`compression`).
- **Snooze to a time you pick** (`snoozeUntil`).
- **Prompt links** (`nook://prompt?…`) opening New session.
- **Read the whole message** and **Earlier messages** in a long conversation (`entry`, `timeline` with `item`).
- **Chat pictures and app icons** (`avatars`, `appIcons`) and **who read your message** (`InboxLine.readers`).
- **Version notices** and *Show the update on your Mac* (`requestUpdate`).
- **Widgets** for the home screen (agent activity, plan limits) and **app shortcuts** on the icon.
- **Mermaid diagrams and math** in answers.
- **Tablet layout** (the iPad's split view) for Android tablets.
