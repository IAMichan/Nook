// Your own key rules (`keybindings.json` in Nook's data folder, as `~/.nook/keybindings.json` on the Mac), read once
// per window and written when Settings › Shortcuts changes a key; every window follows the change.
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { effectiveRules, ruleIsValid, type KeybindingRule } from "./keybindings";

class Keys {
  user = $state<KeybindingRule[]>([]);
  /// Rules in the file Nook could not use, for Settings to show.
  skipped = $state(0);
  rules = $derived(effectiveRules(this.user));
  private started = false;

  start() {
    if (this.started) return;
    this.started = true;
    const load = () => invoke<KeybindingRule[]>("keybindings_read").then((list) => this.take(list)).catch(() => {});
    load();
    listen("keybindings-changed", load).catch(() => {});
  }

  private take(list: unknown) {
    const rules = Array.isArray(list) ? (list as KeybindingRule[]) : [];
    this.user = rules.filter(ruleIsValid);
    this.skipped = rules.length - this.user.length;
  }

  async save(rules: KeybindingRule[]) {
    this.user = rules;
    await invoke("keybindings_write", { rules });
  }
}

export const keys = new Keys();
