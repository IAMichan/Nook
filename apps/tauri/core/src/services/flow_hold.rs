//! Flow on a held modifier alone (`FlowKey` on the Mac): hold the right Ctrl, Alt, Shift or Windows key, talk, let go.
//! The platform's low-level keyboard hook feeds every key event to a [`HoldTracker`]; this file decides what each one
//! means. Virtual-key codes are Windows' (`VK_RCONTROL` and friends). The Mac's `fn` key has no counterpart: Windows
//! does not report it.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HoldKey {
    RightControl,
    RightAlt,
    RightShift,
    RightWin,
}

impl HoldKey {
    pub const ALL: [HoldKey; 4] = [Self::RightControl, Self::RightAlt, Self::RightShift, Self::RightWin];

    /// How the key is kept in the Flow settings (`FlowSettings::key`).
    pub fn setting(self) -> &'static str {
        match self {
            Self::RightControl => "RightControl",
            Self::RightAlt => "RightAlt",
            Self::RightShift => "RightShift",
            Self::RightWin => "RightWin",
        }
    }

    /// The key a setting names; `None` for an ordinary accelerator like "Control+Alt+D".
    pub fn parse(setting: &str) -> Option<Self> {
        let flat: String =
            setting.chars().filter(|c| !c.is_whitespace() && *c != '+' && *c != '-' && *c != '_').collect::<String>().to_lowercase();
        match flat.as_str() {
            "rightcontrol" | "rightctrl" | "rcontrol" | "rctrl" => Some(Self::RightControl),
            "rightalt" | "rightoption" | "ralt" | "altgr" => Some(Self::RightAlt),
            "rightshift" | "rshift" => Some(Self::RightShift),
            "rightwin" | "rightwindows" | "rightmeta" | "rightcommand" | "rwin" => Some(Self::RightWin),
            _ => None,
        }
    }

    /// The virtual-key code.
    pub fn vk(self) -> u32 {
        match self {
            Self::RightControl => 0xA3,
            Self::RightAlt => 0xA5,
            Self::RightShift => 0xA1,
            Self::RightWin => 0x5C,
        }
    }
}

/// Every virtual-key code of a modifier key; pressing one of these is not "another key".
const MODIFIERS: [u32; 11] = [0x10, 0x11, 0x12, 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0x5B, 0x5C];
/// Windows adds this left Ctrl to every AltGr press on layouts that have it; it is part of the key, not another one.
const LEFT_CONTROL: u32 = 0xA2;
const ESCAPE: u32 = 0x1B;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HoldSignal {
    /// The key went down (once per press, not for the repeats of holding it).
    Down,
    Up,
    /// Another key came while the modifier was held: a shortcut such as Ctrl+C, not dictation.
    Other,
    /// Escape while the modifier is held.
    Escape,
}

#[derive(Debug, Clone, Copy)]
pub struct HoldTracker {
    key: HoldKey,
    down: bool,
}

impl HoldTracker {
    pub fn new(key: HoldKey) -> Self {
        Self { key, down: false }
    }

    pub fn key(&self) -> HoldKey {
        self.key
    }

    /// One key event from the keyboard hook. `injected` events (Nook's own paste, other programs' macros) never count.
    pub fn feed(&mut self, vk: u32, pressed: bool, injected: bool) -> Option<HoldSignal> {
        if injected {
            return None;
        }
        if vk == self.key.vk() {
            return match (pressed, self.down) {
                (true, false) => {
                    self.down = true;
                    Some(HoldSignal::Down)
                }
                (false, true) => {
                    self.down = false;
                    Some(HoldSignal::Up)
                }
                _ => None,
            };
        }
        if !pressed || !self.down {
            return None;
        }
        if vk == ESCAPE {
            return Some(HoldSignal::Escape);
        }
        if self.key == HoldKey::RightAlt && vk == LEFT_CONTROL {
            return None;
        }
        // Another modifier alone is not a shortcut yet; the key that follows it is.
        if MODIFIERS.contains(&vk) {
            return None;
        }
        Some(HoldSignal::Other)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_setting() {
        assert_eq!(HoldKey::parse("Right Ctrl"), Some(HoldKey::RightControl));
        assert_eq!(HoldKey::parse("RightAlt"), Some(HoldKey::RightAlt));
        assert_eq!(HoldKey::parse("rightOption"), Some(HoldKey::RightAlt));
        assert_eq!(HoldKey::parse("Control+Alt+D"), None);
        for key in HoldKey::ALL {
            assert_eq!(HoldKey::parse(key.setting()), Some(key));
        }
    }

    #[test]
    fn holding_alone_is_down_then_up_without_the_repeats() {
        let mut t = HoldTracker::new(HoldKey::RightControl);
        assert_eq!(t.feed(0xA3, true, false), Some(HoldSignal::Down));
        assert_eq!(t.feed(0xA3, true, false), None);
        assert_eq!(t.feed(0xA3, true, false), None);
        assert_eq!(t.feed(0xA3, false, false), Some(HoldSignal::Up));
        assert_eq!(t.feed(0xA3, false, false), None);
    }

    #[test]
    fn a_chord_is_not_dictation() {
        let mut t = HoldTracker::new(HoldKey::RightControl);
        t.feed(0xA3, true, false);
        assert_eq!(t.feed(0x43, true, false), Some(HoldSignal::Other));
        // Releasing C does nothing; releasing Ctrl still ends the hold.
        assert_eq!(t.feed(0x43, false, false), None);
        assert_eq!(t.feed(0xA3, false, false), Some(HoldSignal::Up));
        // Without the modifier held, keys mean nothing.
        assert_eq!(t.feed(0x43, true, false), None);
    }

    #[test]
    fn modifiers_escape_and_injected_keys() {
        let mut t = HoldTracker::new(HoldKey::RightAlt);
        t.feed(0xA5, true, false);
        // AltGr's companion left Ctrl, another modifier, and Nook's own paste do not cancel.
        assert_eq!(t.feed(0xA2, true, false), None);
        assert_eq!(t.feed(0xA0, true, false), None);
        assert_eq!(t.feed(0x56, true, true), None);
        assert_eq!(t.feed(0x1B, true, false), Some(HoldSignal::Escape));
        let mut t = HoldTracker::new(HoldKey::RightWin);
        assert_eq!(t.feed(0x5C, true, true), None);
    }
}
