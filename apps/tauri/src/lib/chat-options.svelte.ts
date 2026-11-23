// The chat options of Settings › Accounts & connections (`ChatOptionsSection` on the Mac): how reading works when you
// open a chat, the same for every chat app. Kept on this computer, as the Mac keeps them in its defaults.

const READ_ON_OPEN = "chats.readOnOpen";
const READ_IN_APP_ON_OPEN = "chats.readInAppOnOpen";

function stored(key: string): boolean {
  try {
    return localStorage.getItem(key) !== "false";
  } catch {
    return true;
  }
}

class ChatOptions {
  /** "Read in Nook when opened": a chat you open is read in Nook, also after a restart. */
  readOnOpen = $state(stored(READ_ON_OPEN));
  /** "Also read in the app": the chat's app hears you opened it, where Nook can tell it. */
  readInAppOnOpen = $state(stored(READ_IN_APP_ON_OPEN));

  setReadOnOpen(on: boolean) {
    this.readOnOpen = on;
    localStorage.setItem(READ_ON_OPEN, String(on));
  }

  setReadInAppOnOpen(on: boolean) {
    this.readInAppOnOpen = on;
    localStorage.setItem(READ_IN_APP_ON_OPEN, String(on));
  }

  /** How an opened chat is read: not at all, in Nook only, or in its app too (when its app takes it). */
  readWhenOpened(appTakesIt: boolean): "no" | "nook" | "app" {
    if (!this.readOnOpen) return "no";
    return this.readInAppOnOpen && appTakesIt ? "app" : "nook";
  }
}

export const chatOptions = new ChatOptions();
