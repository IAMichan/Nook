//! The low-level keyboard hook (`WH_KEYBOARD_LL`) behind Flow on a held modifier alone (SV-46). The hook only watches:
//! every event goes on to the program that should get it. Events are handed to a worker thread through a channel, so
//! the hook procedure returns at once (Windows removes a hook that answers slowly).

use std::sync::mpsc::{channel, Sender};
use std::sync::Mutex;

use nook_core::services::flow_hold::{HoldKey, HoldSignal, HoldTracker};
use windows::Win32::Foundation::{LPARAM, LRESULT, WPARAM};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Threading::GetCurrentThreadId;
use windows::Win32::UI::WindowsAndMessaging::{
    CallNextHookEx, GetMessageW, PostThreadMessageW, SetWindowsHookExW, UnhookWindowsHookEx, KBDLLHOOKSTRUCT, LLKHF_INJECTED, MSG,
    WH_KEYBOARD_LL, WM_KEYDOWN, WM_KEYUP, WM_QUIT, WM_SYSKEYDOWN, WM_SYSKEYUP,
};

/// The events of the running hook: the key code, whether it went down, whether a program (not a person) sent it.
static EVENTS: Mutex<Option<Sender<(u32, bool, bool)>>> = Mutex::new(None);
/// The thread that runs the hook, to end it.
static THREAD: Mutex<Option<u32>> = Mutex::new(None);

unsafe extern "system" fn procedure(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code >= 0 {
        let info = &*(lparam.0 as *const KBDLLHOOKSTRUCT);
        let pressed = matches!(wparam.0 as u32, WM_KEYDOWN | WM_SYSKEYDOWN);
        let released = matches!(wparam.0 as u32, WM_KEYUP | WM_SYSKEYUP);
        if pressed || released {
            let injected = info.flags.0 & LLKHF_INJECTED.0 != 0;
            if let Ok(sender) = EVENTS.try_lock() {
                if let Some(sender) = sender.as_ref() {
                    let _ = sender.send((info.vkCode, pressed, injected));
                }
            }
        }
    }
    CallNextHookEx(None, code, wparam, lparam)
}

/// Starts watching `key`; `on_signal` hears what it means. Replaces a hook that already runs.
pub fn start(key: HoldKey, on_signal: impl Fn(HoldSignal) + Send + 'static) {
    stop();
    let (sender, receiver) = channel::<(u32, bool, bool)>();
    *EVENTS.lock().unwrap_or_else(|e| e.into_inner()) = Some(sender);
    std::thread::spawn(move || {
        let mut tracker = HoldTracker::new(key);
        while let Ok((vk, pressed, injected)) = receiver.recv() {
            if let Some(signal) = tracker.feed(vk, pressed, injected) {
                on_signal(signal);
            }
        }
    });
    std::thread::spawn(|| unsafe {
        let module = GetModuleHandleW(None).ok().map(|m| m.into());
        let Ok(hook) = SetWindowsHookExW(WH_KEYBOARD_LL, Some(procedure), module, 0) else {
            log::warn!("Flow: the keyboard hook could not be set");
            return;
        };
        *THREAD.lock().unwrap_or_else(|e| e.into_inner()) = Some(GetCurrentThreadId());
        let mut message = MSG::default();
        while GetMessageW(&mut message, None, 0, 0).as_bool() {}
        let _ = UnhookWindowsHookEx(hook);
    });
}

/// Stops watching.
pub fn stop() {
    // Dropping the sender ends the worker thread.
    *EVENTS.lock().unwrap_or_else(|e| e.into_inner()) = None;
    if let Some(thread) = THREAD.lock().unwrap_or_else(|e| e.into_inner()).take() {
        unsafe {
            let _ = PostThreadMessageW(thread, WM_QUIT, WPARAM(0), LPARAM(0));
        }
    }
}
