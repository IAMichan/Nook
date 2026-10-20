//! Autocomplete on Windows: a low-level keyboard hook on its own thread (`WH_KEYBOARD_LL`, plus `WH_MOUSE_LL` for
//! clicks), the focused field through UI Automation (`TextPattern2`/`TextPattern`, `ValuePattern` as a fallback),
//! typing with `SendInput` (`KEYEVENTF_UNICODE`, never the clipboard), and the ghost-text window's styles.
//!
//! The hook swallows only the accept keys and Escape, and only while a suggestion is on screen (armed); every other key
//! goes to the app untouched. It never records which key was pressed: the controller only learns "a key", "accept",
//! "Escape" or "a click". Password fields, elevated apps and the secure desktop are skipped.

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU32, Ordering};
use std::sync::{Arc, Mutex, RwLock};

use nook_core::platform::{FieldSkip, FocusedField, InputEvent, ScreenRect, TextInput};
use nook_core::services::autocomplete::prefs::{ChordKey, KeyChord};
use windows::core::BOOL;
use windows::Win32::Foundation::{CloseHandle, HANDLE, HWND, LPARAM, LRESULT, POINT, WPARAM};
use windows::Win32::Graphics::Gdi::ClientToScreen;
use windows::Win32::Security::{GetTokenInformation, TokenElevation, TOKEN_ELEVATION, TOKEN_QUERY};
use windows::Win32::System::Com::{CoCreateInstance, CLSCTX_INPROC_SERVER, SAFEARRAY};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Ole::{SafeArrayAccessData, SafeArrayDestroy, SafeArrayGetLBound, SafeArrayGetUBound, SafeArrayUnaccessData};
use windows::Win32::System::StationsAndDesktops::{
    CloseDesktop, GetUserObjectInformationW, OpenInputDesktop, DESKTOP_CONTROL_FLAGS, DESKTOP_READOBJECTS, UOI_NAME,
};
use windows::Win32::System::Threading::{
    GetCurrentProcess, GetCurrentThreadId, OpenProcess, OpenProcessToken, PROCESS_QUERY_LIMITED_INFORMATION,
};
use windows::Win32::UI::Accessibility::*;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetAsyncKeyState, SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYBD_EVENT_FLAGS, KEYEVENTF_KEYUP, KEYEVENTF_UNICODE,
    VIRTUAL_KEY, VK_CAPITAL, VK_CONTROL, VK_ESCAPE, VK_LCONTROL, VK_LMENU, VK_LSHIFT, VK_LWIN, VK_MENU, VK_RCONTROL, VK_RMENU, VK_RSHIFT,
    VK_RWIN, VK_SHIFT,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CallNextHookEx, GetForegroundWindow, GetGUIThreadInfo, GetMessageW, GetWindowLongPtrW, GetWindowThreadProcessId, PostThreadMessageW,
    SetWindowDisplayAffinity, SetWindowLongPtrW, SetWindowPos, SetWindowsHookExW, ShowWindow, UnhookWindowsHookEx, GUITHREADINFO,
    GWL_EXSTYLE, HC_ACTION, HHOOK, HWND_TOPMOST, KBDLLHOOKSTRUCT, LLKHF_INJECTED, MSG, MSLLHOOKSTRUCT, SWP_NOACTIVATE, SWP_SHOWWINDOW,
    SW_HIDE, WDA_EXCLUDEFROMCAPTURE, WH_KEYBOARD_LL, WH_MOUSE_LL, WM_KEYDOWN, WM_KEYUP, WM_LBUTTONDOWN, WM_LBUTTONUP, WM_MBUTTONDOWN,
    WM_QUIT, WM_RBUTTONDOWN, WM_SYSKEYDOWN, WM_SYSKEYUP, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_EX_TRANSPARENT,
};

use super::screen::{com, display_name, exe_path, title};

/// `dwExtraInfo` on the key events Nook sends itself, so the hook lets them through without reporting them.
const MARKER: usize = 0x4E4F_4F4B; // "NOOK"

/// Characters of text before the cursor that are read.
const BEFORE_LIMIT: i32 = 3_000;
/// Characters after the cursor that are read (only the rest of the line is kept).
const AFTER_LIMIT: i32 = 300;

static ARMED: AtomicBool = AtomicBool::new(false);
/// The accept keys, encoded (see `encode`); 0 is off.
static WORD_KEY: AtomicU32 = AtomicU32::new(0);
static ALL_KEY: AtomicU32 = AtomicU32::new(0);
/// The key whose key-up is swallowed too, after its key-down was.
static SWALLOWED: AtomicU32 = AtomicU32::new(0);
/// The emoji picker is open: its keys are reported, clicks on its card taken.
static PICKER: AtomicBool = AtomicBool::new(false);
static RETURN_TAKES: AtomicBool = AtomicBool::new(false);
/// The picker card: left, top, width, height in physical pixels.
static CARD: [AtomicI32; 4] = [AtomicI32::new(0), AtomicI32::new(0), AtomicI32::new(0), AtomicI32::new(0)];
/// A click on the card was taken: its button-up does not reach the app either.
static MOUSE_UP_SWALLOW: AtomicBool = AtomicBool::new(false);
type Sink = Arc<dyn Fn(InputEvent) + Send + Sync>;
static SINK: RwLock<Option<Sink>> = RwLock::new(None);

const SHIFT: u32 = 1 << 16;
const CONTROL: u32 = 1 << 17;
const ALT: u32 = 1 << 18;

fn encode(chord: Option<KeyChord>) -> u32 {
    let Some(chord) = chord else { return 0 };
    let vk: u32 = match chord.key {
        ChordKey::Tab => 0x09,
        ChordKey::Right => 0x27,
        ChordKey::End => 0x23,
        // VK_OEM_3: ` on US and most layouts.
        ChordKey::Backtick => 0xC0,
        ChordKey::Enter => 0x0D,
    };
    vk | if chord.shift { SHIFT } else { 0 } | if chord.control { CONTROL } else { 0 } | if chord.alt { ALT } else { 0 }
}

fn down(vk: VIRTUAL_KEY) -> bool {
    unsafe { GetAsyncKeyState(vk.0 as i32) < 0 }
}

fn is_modifier(vk: u32) -> bool {
    [VK_SHIFT, VK_LSHIFT, VK_RSHIFT, VK_CONTROL, VK_LCONTROL, VK_RCONTROL, VK_MENU, VK_LMENU, VK_RMENU, VK_LWIN, VK_RWIN, VK_CAPITAL]
        .iter()
        .any(|k| k.0 as u32 == vk)
}

fn emit(event: InputEvent) {
    if let Some(sink) = SINK.read().unwrap_or_else(|e| e.into_inner()).as_ref() {
        sink(event);
    }
}

unsafe extern "system" fn keyboard_hook(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code == HC_ACTION as i32 {
        let info = unsafe { &*(lparam.0 as *const KBDLLHOOKSTRUCT) };
        let injected = info.flags.0 & LLKHF_INJECTED.0 != 0;
        // Nook's own typing: through, unreported.
        if !(injected && info.dwExtraInfo == MARKER) {
            let message = wparam.0 as u32;
            let vk = info.vkCode;
            if message == WM_KEYUP || message == WM_SYSKEYUP {
                if SWALLOWED.load(Ordering::SeqCst) == vk {
                    SWALLOWED.store(0, Ordering::SeqCst);
                    return LRESULT(1);
                }
            } else if (message == WM_KEYDOWN || message == WM_SYSKEYDOWN) && !is_modifier(vk) {
                let windows_key = down(VK_LWIN) || down(VK_RWIN);
                let chord = vk
                    | if down(VK_SHIFT) { SHIFT } else { 0 }
                    | if down(VK_CONTROL) { CONTROL } else { 0 }
                    | if down(VK_MENU) { ALT } else { 0 };
                if ARMED.load(Ordering::SeqCst) && !windows_key {
                    let event = if chord == WORD_KEY.load(Ordering::SeqCst) {
                        Some(InputEvent::AcceptWord)
                    } else if chord == ALL_KEY.load(Ordering::SeqCst) {
                        Some(InputEvent::AcceptAll)
                    } else if chord == VK_ESCAPE.0 as u32 {
                        Some(InputEvent::Escape)
                    } else {
                        None
                    };
                    if let Some(event) = event {
                        SWALLOWED.store(vk, Ordering::SeqCst);
                        emit(event);
                        return LRESULT(1);
                    }
                    if PICKER.load(Ordering::SeqCst) {
                        match picker_key(vk, chord) {
                            Some((event, true)) => {
                                SWALLOWED.store(vk, Ordering::SeqCst);
                                emit(event);
                                return LRESULT(1);
                            }
                            Some((event, false)) => {
                                emit(event);
                                return unsafe { CallNextHookEx(None, code, wparam, lparam) };
                            }
                            None => {}
                        }
                    }
                }
                PICKER.store(false, Ordering::SeqCst);
                // Any other key: the suggestion no longer fits until the field is read again.
                ARMED.store(false, Ordering::SeqCst);
                emit(InputEvent::Key);
            }
        }
    }
    unsafe { CallNextHookEx(None, code, wparam, lparam) }
}

/// What a key does while the picker is open, and whether it is swallowed. `None`: it closes the picker.
fn picker_key(vk: u32, chord: u32) -> Option<(InputEvent, bool)> {
    let plain = chord == vk;
    let typing = chord & (CONTROL | ALT) == 0;
    let shift = chord & SHIFT != 0;
    match vk {
        0x25 if plain => Some((InputEvent::PickerMove { dx: -1, dy: 0 }, true)),
        0x26 if plain => Some((InputEvent::PickerMove { dx: 0, dy: -1 }, true)),
        0x27 if plain => Some((InputEvent::PickerMove { dx: 1, dy: 0 }, true)),
        0x28 if plain => Some((InputEvent::PickerMove { dx: 0, dy: 1 }, true)),
        0x31..=0x39 if typing => Some((InputEvent::PickerNumber((vk - 0x30) as u8), true)),
        0x0D if plain && RETURN_TAKES.load(Ordering::SeqCst) => Some((InputEvent::PickerReturn, true)),
        0x08 if plain => Some((InputEvent::PickerBackspace, false)),
        0x30 if typing => Some((InputEvent::PickerLetter('0'), false)),
        0x41..=0x5A if typing => Some((InputEvent::PickerLetter(((vk as u8) + 32) as char), false)),
        // VK_OEM_MINUS and VK_OEM_PLUS (US layout): "-", "_" and "+" are allowed in names (":+1").
        0xBD if typing => Some((InputEvent::PickerLetter(if shift { '_' } else { '-' }), false)),
        0xBB if typing && shift => Some((InputEvent::PickerLetter('+'), false)),
        _ => None,
    }
}

unsafe extern "system" fn mouse_hook(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code == HC_ACTION as i32 {
        let message = wparam.0 as u32;
        if message == WM_LBUTTONUP && MOUSE_UP_SWALLOW.swap(false, Ordering::SeqCst) {
            return LRESULT(1);
        }
        if message == WM_LBUTTONDOWN && PICKER.load(Ordering::SeqCst) {
            let info = unsafe { &*(lparam.0 as *const MSLLHOOKSTRUCT) };
            let [left, top, width, height] = [0, 1, 2, 3].map(|i| CARD[i].load(Ordering::SeqCst));
            let (x, y) = (info.pt.x - left, info.pt.y - top);
            if x >= 0 && y >= 0 && x < width && y < height {
                MOUSE_UP_SWALLOW.store(true, Ordering::SeqCst);
                emit(InputEvent::PickerClick { x: x as f64, y: y as f64 });
                return LRESULT(1);
            }
        }
        if message == WM_LBUTTONDOWN || message == WM_RBUTTONDOWN || message == WM_MBUTTONDOWN {
            PICKER.store(false, Ordering::SeqCst);
            ARMED.store(false, Ordering::SeqCst);
            emit(InputEvent::Click);
        }
    }
    unsafe { CallNextHookEx(None, code, wparam, lparam) }
}

thread_local! {
    static AUTOMATION: std::cell::RefCell<Option<IUIAutomation>> = const { std::cell::RefCell::new(None) };
}

fn automation() -> Option<IUIAutomation> {
    AUTOMATION.with(|cell| {
        let mut slot = cell.borrow_mut();
        if slot.is_none() {
            com();
            *slot = unsafe { CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER).ok() };
        }
        slot.clone()
    })
}

/// The input desktop is not the normal one: a UAC prompt or the lock screen.
fn secure_desktop() -> bool {
    unsafe {
        let Ok(desk) = OpenInputDesktop(DESKTOP_CONTROL_FLAGS(0), false, DESKTOP_READOBJECTS) else { return true };
        let mut name = [0u16; 64];
        let mut needed = 0u32;
        let ok = GetUserObjectInformationW(
            HANDLE(desk.0),
            UOI_NAME,
            Some(name.as_mut_ptr() as *mut _),
            (name.len() * 2) as u32,
            Some(&mut needed),
        )
        .is_ok();
        let _ = CloseDesktop(desk);
        let len = name.iter().position(|c| *c == 0).unwrap_or(name.len());
        !ok || !String::from_utf16_lossy(&name[..len]).eq_ignore_ascii_case("Default")
    }
}

fn token_elevated(process: HANDLE) -> Option<bool> {
    unsafe {
        let mut token = HANDLE::default();
        OpenProcessToken(process, TOKEN_QUERY, &mut token).ok()?;
        let mut elevation = TOKEN_ELEVATION::default();
        let mut size = 0u32;
        let ok = GetTokenInformation(
            token,
            TokenElevation,
            Some(&mut elevation as *mut _ as *mut _),
            std::mem::size_of::<TOKEN_ELEVATION>() as u32,
            &mut size,
        )
        .is_ok();
        let _ = CloseHandle(token);
        ok.then_some(elevation.TokenIsElevated != 0)
    }
}

/// Whether the app runs with more rights than Nook: Windows then blocks reading it and typing into it.
fn more_rights_than_us(pid: u32) -> bool {
    let ours = token_elevated(unsafe { GetCurrentProcess() }).unwrap_or(false);
    if ours {
        return false;
    }
    let theirs = unsafe {
        match OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) {
            Ok(handle) => {
                let elevated = token_elevated(handle);
                let _ = CloseHandle(handle);
                elevated
            }
            Err(_) => None,
        }
    };
    // Not allowed to look: treat it as elevated rather than type into it blindly.
    theirs.unwrap_or(true)
}

/// Rectangles from a `GetBoundingRectangles` array: left, top, width, height, repeated.
fn rectangles(array: *mut SAFEARRAY) -> Vec<ScreenRect> {
    if array.is_null() {
        return vec![];
    }
    let mut result = Vec::new();
    unsafe {
        let lower = SafeArrayGetLBound(array, 1).unwrap_or(0);
        let upper = SafeArrayGetUBound(array, 1).unwrap_or(-1);
        let count = (upper - lower + 1).max(0) as usize;
        let mut data: *mut core::ffi::c_void = std::ptr::null_mut();
        if count >= 4 && SafeArrayAccessData(array, &mut data).is_ok() {
            let values = std::slice::from_raw_parts(data as *const f64, count);
            for &[x, y, width, height] in values.as_chunks::<4>().0 {
                result.push(ScreenRect { x, y, width, height });
            }
            let _ = SafeArrayUnaccessData(array);
        }
        let _ = SafeArrayDestroy(array);
    }
    result
}

/// Where the cursor is: the caret range's own rectangle, or the right edge of the character before it.
fn caret_rect(caret: &IUIAutomationTextRange) -> Option<ScreenRect> {
    unsafe {
        if let Some(rect) = caret.GetBoundingRectangles().ok().map(rectangles).and_then(|r| r.into_iter().next()) {
            if rect.height > 0.0 {
                return Some(ScreenRect { width: rect.width.max(1.0), ..rect });
            }
        }
        let previous = caret.Clone().ok()?;
        previous.MoveEndpointByUnit(TextPatternRangeEndpoint_Start, TextUnit_Character, -1).ok()?;
        let rect = previous.GetBoundingRectangles().ok().map(rectangles)?.into_iter().last()?;
        (rect.height > 0.0).then_some(ScreenRect { x: rect.x + rect.width, y: rect.y, width: 1.0, height: rect.height })
    }
}

/// The classic Win32 caret of the foreground thread (Notepad, edit controls), in screen pixels.
fn win32_caret(hwnd: HWND) -> Option<ScreenRect> {
    unsafe {
        let thread = GetWindowThreadProcessId(hwnd, None);
        let mut info = GUITHREADINFO { cbSize: std::mem::size_of::<GUITHREADINFO>() as u32, ..Default::default() };
        GetGUIThreadInfo(thread, &mut info).ok()?;
        if info.hwndCaret.0.is_null() {
            return None;
        }
        let mut point = POINT { x: info.rcCaret.left, y: info.rcCaret.top };
        if !ClientToScreen(info.hwndCaret, &mut point).as_bool() {
            return None;
        }
        let height = (info.rcCaret.bottom - info.rcCaret.top) as f64;
        (height > 0.0).then_some(ScreenRect { x: point.x as f64, y: point.y as f64, width: 1.0, height })
    }
}

/// The rest of the line after the cursor.
fn line_rest(text: &str) -> String {
    text.split(['\n', '\r', '\u{2028}', '\u{2029}', '\u{0B}']).next().unwrap_or("").to_string()
}

fn key_input(vk: u16, scan: u16, flags: KEYBD_EVENT_FLAGS) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 { ki: KEYBDINPUT { wVk: VIRTUAL_KEY(vk), wScan: scan, dwFlags: flags, time: 0, dwExtraInfo: MARKER } },
    }
}

/// `delete` Backspaces, then `text` as Unicode key events, in one `SendInput`, all marked as Nook's own.
fn send_keys(delete: usize, text: &str) -> Result<(), String> {
    let mut inputs: Vec<INPUT> = Vec::new();
    for _ in 0..delete {
        inputs.push(key_input(0x08, 0, KEYBD_EVENT_FLAGS(0)));
        inputs.push(key_input(0x08, 0, KEYEVENTF_KEYUP));
    }
    for unit in text.encode_utf16() {
        inputs.push(key_input(0, unit, KEYEVENTF_UNICODE));
        inputs.push(key_input(0, unit, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));
    }
    if inputs.is_empty() {
        return Ok(());
    }
    let sent = unsafe { SendInput(&inputs, std::mem::size_of::<INPUT>() as i32) };
    if sent as usize == inputs.len() {
        Ok(())
    } else {
        Err("Windows liet Nook niet typen (een app met meer rechten heeft de focus).".into())
    }
}

pub struct WindowsTextInput {
    thread: Mutex<Option<u32>>,
    names: Mutex<BTreeMap<String, String>>,
}

impl WindowsTextInput {
    pub fn new() -> Self {
        Self { thread: Mutex::new(None), names: Mutex::new(BTreeMap::new()) }
    }

    fn app(&self, pid: u32) -> (String, String) {
        let path = exe_path(pid).unwrap_or_default();
        let file = std::path::Path::new(&path).file_name().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
        let name = {
            let mut names = self.names.lock().unwrap_or_else(|e| e.into_inner());
            names
                .entry(path.clone())
                .or_insert_with(|| display_name(&path).unwrap_or_else(|| file.trim_end_matches(".exe").to_string()))
                .clone()
        };
        (file, name)
    }

    fn read(&self) -> Result<FocusedField, FieldSkip> {
        if secure_desktop() {
            return Err(FieldSkip::SecureDesktop);
        }
        let hwnd = unsafe { GetForegroundWindow() };
        if hwnd.0.is_null() {
            return Err(FieldSkip::NoField);
        }
        let mut pid = 0u32;
        unsafe { GetWindowThreadProcessId(hwnd, Some(&mut pid)) };
        if pid == std::process::id() {
            return Err(FieldSkip::OwnApp);
        }
        if more_rights_than_us(pid) {
            return Err(FieldSkip::Elevated);
        }
        let automation = automation().ok_or(FieldSkip::NoField)?;
        unsafe {
            let element = automation.GetFocusedElement().map_err(|_| FieldSkip::NoField)?;
            if element.CurrentIsPassword().map(|b| b.as_bool()).unwrap_or(true) {
                return Err(FieldSkip::Password);
            }
            if element.CurrentProcessId().map(|p| p as u32).unwrap_or(0) == std::process::id() {
                return Err(FieldSkip::OwnApp);
            }
            let value = element.GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId).ok();
            if value.as_ref().is_some_and(|v| v.CurrentIsReadOnly().map(|b| b.as_bool()).unwrap_or(true)) {
                return Err(FieldSkip::NoField);
            }
            let kind = element.CurrentControlType().unwrap_or(UIA_CustomControlTypeId);
            let editable_document = kind != UIA_DocumentControlTypeId
                || value.is_some()
                || element
                    .GetCurrentPropertyValue(UIA_IsTextEditPatternAvailablePropertyId)
                    .is_ok_and(|v| bool::try_from(&v).unwrap_or(false));
            let (app_id, app_name) = self.app(pid);
            let field = element.CurrentBoundingRectangle().ok().map(|r| ScreenRect {
                x: r.left as f64,
                y: r.top as f64,
                width: (r.right - r.left) as f64,
                height: (r.bottom - r.top) as f64,
            });
            let mut result = FocusedField { app_id, app_name, window_title: title(hwnd), field, ..Default::default() };

            let text2 = element.GetCurrentPatternAs::<IUIAutomationTextPattern2>(UIA_TextPattern2Id).ok();
            let text = element.GetCurrentPatternAs::<IUIAutomationTextPattern>(UIA_TextPatternId).ok();
            if let (Some(pattern), true) = (text.as_ref(), editable_document) {
                let selection = pattern.GetSelection().ok();
                let first = selection.as_ref().and_then(|s| (s.Length().unwrap_or(0) > 0).then(|| s.GetElement(0).ok()).flatten());
                result.has_selection = first.as_ref().is_some_and(|r| r.GetText(2).map(|t| !t.is_empty()).unwrap_or(false));
                let caret = match text2.as_ref() {
                    Some(p2) => {
                        let mut active = BOOL(0);
                        p2.GetCaretRange(&mut active).ok().or(first)
                    }
                    None => first,
                };
                let caret = caret.ok_or(FieldSkip::NoField)?;
                if let Ok(before) = caret.Clone() {
                    let _ = before.MoveEndpointByRange(TextPatternRangeEndpoint_End, &caret, TextPatternRangeEndpoint_Start);
                    let _ = before.MoveEndpointByUnit(TextPatternRangeEndpoint_Start, TextUnit_Character, -BEFORE_LIMIT);
                    result.before = before.GetText(BEFORE_LIMIT + 10).map(|t| t.to_string()).unwrap_or_default();
                }
                if let Ok(after) = caret.Clone() {
                    let _ = after.MoveEndpointByRange(TextPatternRangeEndpoint_Start, &caret, TextPatternRangeEndpoint_End);
                    let _ = after.MoveEndpointByUnit(TextPatternRangeEndpoint_End, TextUnit_Character, AFTER_LIMIT);
                    result.after = line_rest(&after.GetText(AFTER_LIMIT).map(|t| t.to_string()).unwrap_or_default());
                }
                result.caret = caret_rect(&caret).or_else(|| win32_caret(hwnd));
            } else if let Some(value) = value {
                // No text pattern: the whole value, with the cursor taken to be at its end.
                let text = value.CurrentValue().map(|v| v.to_string()).unwrap_or_default();
                let count = text.chars().count();
                result.before = text.chars().skip(count.saturating_sub(BEFORE_LIMIT as usize)).collect();
                result.caret = win32_caret(hwnd);
            } else {
                return Err(FieldSkip::NoField);
            }
            Ok(result)
        }
    }
}

impl TextInput for WindowsTextInput {
    fn available(&self) -> bool {
        true
    }

    fn status(&self) -> String {
        String::new()
    }

    fn start(&self, on_event: Arc<dyn Fn(InputEvent) + Send + Sync>) -> Result<(), String> {
        *SINK.write().unwrap_or_else(|e| e.into_inner()) = Some(on_event);
        let mut thread = self.thread.lock().unwrap_or_else(|e| e.into_inner());
        if thread.is_some() {
            return Ok(());
        }
        let (tx, rx) = std::sync::mpsc::channel::<Result<u32, String>>();
        std::thread::Builder::new()
            .name("nook-autocomplete-hook".into())
            .spawn(move || unsafe {
                let module = GetModuleHandleW(None).ok().map(|m| m.into());
                let keyboard = SetWindowsHookExW(WH_KEYBOARD_LL, Some(keyboard_hook), module, 0);
                let mouse = SetWindowsHookExW(WH_MOUSE_LL, Some(mouse_hook), module, 0);
                let keyboard: HHOOK = match keyboard {
                    Ok(hook) => hook,
                    Err(e) => {
                        let _ = tx.send(Err(format!("Windows liet Nook de toetsen niet volgen: {e}")));
                        return;
                    }
                };
                let _ = tx.send(Ok(GetCurrentThreadId()));
                let mut message = MSG::default();
                // The hooks run inside this loop; WM_QUIT (from `stop`) ends it.
                while GetMessageW(&mut message, None, 0, 0).as_bool() {}
                let _ = UnhookWindowsHookEx(keyboard);
                if let Ok(mouse) = mouse {
                    let _ = UnhookWindowsHookEx(mouse);
                }
            })
            .map_err(|e| e.to_string())?;
        let id = rx.recv().map_err(|e| e.to_string())??;
        *thread = Some(id);
        Ok(())
    }

    fn stop(&self) {
        ARMED.store(false, Ordering::SeqCst);
        *SINK.write().unwrap_or_else(|e| e.into_inner()) = None;
        if let Some(id) = self.thread.lock().unwrap_or_else(|e| e.into_inner()).take() {
            unsafe {
                let _ = PostThreadMessageW(id, WM_QUIT, WPARAM(0), LPARAM(0));
            }
        }
    }

    fn set_keys(&self, word: Option<KeyChord>, all: Option<KeyChord>) {
        WORD_KEY.store(encode(word), Ordering::SeqCst);
        ALL_KEY.store(encode(all), Ordering::SeqCst);
    }

    fn arm(&self, armed: bool) {
        ARMED.store(armed, Ordering::SeqCst);
    }

    fn focused_field(&self) -> Result<FocusedField, FieldSkip> {
        self.read()
    }

    fn type_text(&self, text: &str) -> Result<(), String> {
        send_keys(0, text)
    }

    fn replace_text(&self, delete: usize, text: &str) -> Result<(), String> {
        send_keys(delete, text)
    }

    fn set_picker(&self, card: Option<ScreenRect>, return_takes: bool) {
        if let Some(card) = card {
            for (slot, value) in CARD.iter().zip([card.x, card.y, card.width, card.height]) {
                slot.store(value.round() as i32, Ordering::SeqCst);
            }
        }
        RETURN_TAKES.store(return_takes, Ordering::SeqCst);
        PICKER.store(card.is_some(), Ordering::SeqCst);
    }

    fn prepare_overlay(&self, handle: isize) {
        let hwnd = HWND(handle as *mut _);
        unsafe {
            let style = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
            let extra = (WS_EX_TRANSPARENT.0 | WS_EX_NOACTIVATE.0 | WS_EX_TOOLWINDOW.0 | WS_EX_TOPMOST.0) as isize;
            SetWindowLongPtrW(hwnd, GWL_EXSTYLE, style | extra);
            // Screenshots and Nook's own screen reading do not see the ghost text.
            let _ = SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);
        }
    }

    fn place_overlay(&self, handle: isize, rect: Option<ScreenRect>) {
        let hwnd = HWND(handle as *mut _);
        unsafe {
            match rect {
                Some(r) => {
                    let _ = SetWindowPos(
                        hwnd,
                        Some(HWND_TOPMOST),
                        r.x.round() as i32,
                        r.y.round() as i32,
                        r.width.round().max(1.0) as i32,
                        r.height.round().max(1.0) as i32,
                        SWP_NOACTIVATE | SWP_SHOWWINDOW,
                    );
                }
                None => {
                    let _ = ShowWindow(hwnd, SW_HIDE);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_chords() {
        assert_eq!(encode(KeyChord::parse("Tab")), 0x09);
        assert_eq!(encode(KeyChord::parse("Shift+Tab")), 0x09 | SHIFT);
        assert_eq!(encode(KeyChord::parse("Alt+Right")), 0x27 | ALT);
        assert_eq!(encode(None), 0);
        assert_eq!(line_rest("abc\ndef"), "abc");
        assert_eq!(picker_key(0x41, 0x41), Some((InputEvent::PickerLetter('a'), false)));
        assert_eq!(picker_key(0x41, 0x41 | SHIFT), Some((InputEvent::PickerLetter('a'), false)));
        assert_eq!(picker_key(0x41, 0x41 | CONTROL), None);
        assert_eq!(picker_key(0x33, 0x33), Some((InputEvent::PickerNumber(3), true)));
        assert_eq!(picker_key(0x20, 0x20), None);
    }
}
