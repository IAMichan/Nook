//! Windows UI Automation and `SendInput` driver for `read_ui` and `control_ui` (SV-72).
//!
//! Wraps [`WindowsScreen`] in [`WindowsUiScreen`] so every existing `ScreenReader` capability delegates cleanly while
//! adding UI element tree inspection (`ui_elements`), real mouse/keyboard actuation (`ui_perform`), and live hit-test /
//! focus queries (`ui_label_at`, `ui_focused_label`) for takeover checkpoints.
//!
//! Hard safety boundaries enforced directly in the driver:
//! - Never reads or controls Nook's own process, password managers, terminals, shells, or admin tools (`is_blocked_app`).
//! - Never reads values from or types into password fields (`IsPassword` / `Element.secure`).
//! - Never types credit-card or social security numbers (`takeover::contains_high_risk_number`).
//! - Never sends forbidden system shortcuts (`ui_control::forbidden`).
//! - Refuses elevated apps and the secure desktop (UAC / lock screen).
//! - Verifies window ownership (`owns_point` / foreground PID) right before clicks, drags, scrolls, and typing.
//! - Marks every injected `SendInput` event with `NOOK_MARKER` (`0x4E4F_4F4B`) so Nook's autocomplete hook ignores it.

use std::time::Duration;

use nook_core::brain::open_browser_tab::BrowserTabResult;
use nook_core::brain::takeover;
use nook_core::brain::ui_control::{self, Action, Element, KeyCombo, Modifier, Step};
use nook_core::i18n::{tr, trf};
use nook_core::platform::{Capture, MenuCommandOutcome, RunningApp, ScreenReader, SeenWindow, WindowText};
use windows::core::BSTR;
use windows::Win32::Foundation::{CloseHandle, HANDLE, HWND, POINT, RECT};
use windows::Win32::Security::{GetTokenInformation, TokenElevation, TOKEN_ELEVATION, TOKEN_QUERY};
use windows::Win32::System::Com::{CoCreateInstance, CLSCTX_INPROC_SERVER};
use windows::Win32::System::StationsAndDesktops::{
    CloseDesktop, GetUserObjectInformationW, OpenInputDesktop, DESKTOP_CONTROL_FLAGS, DESKTOP_READOBJECTS, UOI_NAME,
};
use windows::Win32::System::Threading::{
    GetCurrentProcess, OpenProcess, OpenProcessToken, PROCESS_QUERY_LIMITED_INFORMATION,
};
use windows::Win32::UI::Accessibility::*;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, INPUT_MOUSE, KEYBDINPUT, KEYBD_EVENT_FLAGS, KEYEVENTF_EXTENDEDKEY,
    KEYEVENTF_KEYUP, KEYEVENTF_UNICODE, MOUSEEVENTF_ABSOLUTE, MOUSEEVENTF_HWHEEL, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP,
    MOUSEEVENTF_MOVE, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP, MOUSEEVENTF_VIRTUALDESK, MOUSEEVENTF_WHEEL, MOUSEINPUT,
    MOUSE_EVENT_FLAGS, VIRTUAL_KEY,
};
use windows::Win32::UI::WindowsAndMessaging::{
    GetAncestor, GetForegroundWindow, GetSystemMetrics, GetWindowLongW, GetWindowRect, GetWindowThreadProcessId, IsIconic,
    IsWindowVisible, SetCursorPos, SetForegroundWindow, ShowWindow, WindowFromPoint, GA_ROOT, GWL_EXSTYLE, SM_CXVIRTUALSCREEN,
    SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN, SW_RESTORE, WS_EX_TOOLWINDOW,
};

use super::screen::{cloaked, com, display_name, exe_path, title, top_windows, WindowsScreen};

/// Matches `autocomplete::MARKER` (`"NOOK"`): tells Nook's low-level hooks to ignore Nook's own injected events.
const NOOK_MARKER: usize = 0x4E4F_4F4B;
const WHEEL_DELTA: i32 = 120;
const MAX_WINDOWS: usize = 4;
const MAX_ELEMENTS: usize = 900;
const MAX_OFFSCREEN: usize = 300;
const MAX_SCAN: i32 = 5_000;
const DRAG_STEPS: usize = 20;

/// Full Windows `ScreenReader`: delegates screen/OCR/menu/browser-tab reads to [`WindowsScreen`] and adds
/// UI Automation inspection + `SendInput` actuation for `read_ui` and `control_ui`.
pub struct WindowsUiScreen(WindowsScreen);

impl WindowsUiScreen {
    pub fn new() -> Self {
        Self(WindowsScreen::new())
    }
}

impl ScreenReader for WindowsUiScreen {
    fn available(&self) -> bool {
        self.0.available()
    }

    fn status(&self) -> String {
        self.0.status()
    }

    fn frontmost(&self) -> Option<WindowText> {
        self.0.frontmost()
    }

    fn all_windows(&self) -> Vec<WindowText> {
        self.0.all_windows()
    }

    fn windows(&self) -> Vec<SeenWindow> {
        self.0.windows()
    }

    fn read_window(&self, id: &str) -> Option<(String, u64)> {
        self.0.read_window(id)
    }

    fn fingerprint(&self, id: &str) -> Option<u64> {
        self.0.fingerprint(id)
    }

    fn read_app(&self, query: &str, limit: usize) -> Result<Vec<(String, String)>, String> {
        self.0.read_app(query, limit)
    }

    fn active_app(&self) -> Option<RunningApp> {
        self.0.active_app()
    }

    fn running_apps(&self) -> Vec<RunningApp> {
        self.0.running_apps()
    }

    fn list_app_menu(&self, pid: u32) -> Result<Vec<String>, String> {
        ensure_allowed_process(pid)?;
        self.0.list_app_menu(pid)
    }

    fn click_app_menu(&self, pid: u32, path: &[String]) -> Result<MenuCommandOutcome, String> {
        ensure_allowed_process(pid)?;
        self.0.click_app_menu(pid, path)
    }

    fn ui_elements(&self, pid: u32) -> Result<(String, Vec<Element>), String> {
        read_ui_elements(pid)
    }

    fn ui_perform(&self, pid: u32, step: &Step, target: Option<&Element>, to: Option<&Element>) -> Result<String, String> {
        perform_step(pid, step, target, to)
    }

    fn ui_label_at(&self, x: f64, y: f64) -> Option<String> {
        label_at_point(x, y)
    }

    fn ui_focused_label(&self, pid: u32) -> Option<String> {
        focused_label_for_pid(pid)
    }

    fn can_capture(&self) -> bool {
        self.0.can_capture()
    }

    fn read_image_text(&self, rgba: &[u8], width: u32, height: u32) -> Option<String> {
        self.0.read_image_text(rgba, width, height)
    }

    fn capture_screen(&self) -> Result<Capture, String> {
        self.0.capture_screen()
    }

    fn idle_seconds(&self) -> f64 {
        self.0.idle_seconds()
    }

    fn read_browser_tab(&self, browser: Option<&str>, tab: Option<&str>) -> Result<BrowserTabResult, String> {
        self.0.read_browser_tab(browser, tab)
    }
}

// MARK: Process & desktop safety checks

fn process_names(pid: u32) -> (String, String) {
    let path = exe_path(pid).unwrap_or_default();
    let exe = std::path::Path::new(&path)
        .file_stem()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_default();
    let name = display_name(&path).unwrap_or_else(|| exe.clone());
    (exe, name)
}

fn is_blocked_pid(pid: u32) -> Option<String> {
    if pid == 0 || pid == std::process::id() {
        return Some("Nook".into());
    }
    let (exe, name) = process_names(pid);
    if (!exe.is_empty() && ui_control::is_blocked_app(&exe)) || (!name.is_empty() && ui_control::is_blocked_app(&name)) {
        return Some(if name.is_empty() { exe } else { name });
    }
    None
}

fn secure_desktop() -> bool {
    unsafe {
        let Ok(desk) = OpenInputDesktop(DESKTOP_CONTROL_FLAGS(0), false, DESKTOP_READOBJECTS) else {
            return true;
        };
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

fn is_elevated(pid: u32) -> bool {
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
    theirs.unwrap_or(true)
}

fn ensure_allowed_process(pid: u32) -> Result<(), String> {
    if secure_desktop() {
        return Err(tr(
            "Nook kan dit scherm niet besturen (beveiligd bureaublad of vergrendelscherm).",
            "Nook cannot control this screen (secure desktop or lock screen).",
        )
        .into());
    }
    if let Some(app) = is_blocked_pid(pid) {
        return Err(trf(
            "Nook bestuurt {app} niet: die app bewaart wachtwoorden, voert commando's uit of is Nook zelf.",
            "Nook does not control {app}: it holds passwords, runs commands or is Nook itself.",
            &[("app", &app)],
        ));
    }
    if is_elevated(pid) {
        return Err(tr(
            "Windows laat Nook deze app niet besturen omdat hij als administrator draait.",
            "Windows does not allow Nook to control this app because it runs as administrator.",
        )
        .into());
    }
    Ok(())
}

// MARK: Windows of a process

fn windows_for_pid(pid: u32) -> Vec<HWND> {
    let front = unsafe { GetForegroundWindow() };
    let mut list: Vec<HWND> = top_windows()
        .into_iter()
        .filter(|&hwnd| unsafe {
            if !IsWindowVisible(hwnd).as_bool() || cloaked(hwnd) {
                return false;
            }
            if (GetWindowLongW(hwnd, GWL_EXSTYLE) as u32) & WS_EX_TOOLWINDOW.0 != 0 {
                return false;
            }
            let mut win_pid = 0u32;
            GetWindowThreadProcessId(hwnd, Some(&mut win_pid));
            if win_pid != pid {
                return false;
            }
            let mut rect = RECT::default();
            if GetWindowRect(hwnd, &mut rect).is_err() {
                return false;
            }
            (rect.right - rect.left) > 40 && (rect.bottom - rect.top) > 40
        })
        .collect();
    if let Some(pos) = list.iter().position(|&h| h == front) {
        let fg = list.remove(pos);
        list.insert(0, fg);
    }
    list.truncate(MAX_WINDOWS);
    list
}

fn bring_to_front(hwnd: HWND) {
    unsafe {
        if IsIconic(hwnd).as_bool() {
            let _ = ShowWindow(hwnd, SW_RESTORE);
        }
        let _ = SetForegroundWindow(hwnd);
    }
    std::thread::sleep(Duration::from_millis(120));
}

fn foreground_pid() -> Option<u32> {
    let hwnd = unsafe { GetForegroundWindow() };
    if hwnd.0.is_null() {
        return None;
    }
    let mut pid = 0u32;
    unsafe { GetWindowThreadProcessId(hwnd, Some(&mut pid)) };
    (pid != 0).then_some(pid)
}

fn owns_point(x: f64, y: f64, pid: u32) -> bool {
    let pt = POINT { x: x.round() as i32, y: y.round() as i32 };
    let hit = unsafe { WindowFromPoint(pt) };
    if hit.0.is_null() {
        return false;
    }
    let mut hit_pid = 0u32;
    unsafe { GetWindowThreadProcessId(hit, Some(&mut hit_pid)) };
    if hit_pid == pid {
        return true;
    }
    let root = unsafe { GetAncestor(hit, GA_ROOT) };
    if !root.0.is_null() {
        let mut root_pid = 0u32;
        unsafe { GetWindowThreadProcessId(root, Some(&mut root_pid)) };
        if root_pid == pid {
            return true;
        }
    }
    false
}

fn uia() -> Result<IUIAutomation, String> {
    com();
    unsafe { CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER) }
        .map_err(|e| format!("UI Automation unavailable: {e}"))
}

// MARK: read_ui (UI Automation tree)

fn clean_text(raw: &str) -> String {
    raw.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn is_toggle_switch(localized: &str) -> bool {
    let lower = localized.to_lowercase();
    lower.contains("switch") || lower.contains("schakelaar") || lower.contains("schalter") || lower.contains("interruptor")
}

fn read_ui_elements(pid: u32) -> Result<(String, Vec<Element>), String> {
    ensure_allowed_process(pid)?;
    let wins = windows_for_pid(pid);
    if wins.is_empty() {
        return Err(tr("Geen zichtbaar venster gevonden voor deze app.", "No visible window found for this app.").into());
    }
    let win_title = title(wins[0]);
    let automation = uia()?;
    let mut out: Vec<Element> = Vec::new();
    let mut offscreen_count = 0usize;

    unsafe {
        let cache = automation.CreateCacheRequest().map_err(|e| e.to_string())?;
        let _ = cache.AddProperty(UIA_NamePropertyId);
        let _ = cache.AddProperty(UIA_ControlTypePropertyId);
        let _ = cache.AddProperty(UIA_IsPasswordPropertyId);
        let _ = cache.AddProperty(UIA_IsEnabledPropertyId);
        let _ = cache.AddProperty(UIA_HasKeyboardFocusPropertyId);
        let _ = cache.AddProperty(UIA_BoundingRectanglePropertyId);
        let _ = cache.AddProperty(UIA_IsOffscreenPropertyId);
        let _ = cache.AddProperty(UIA_LocalizedControlTypePropertyId);
        let _ = cache.AddProperty(UIA_HelpTextPropertyId);
        let condition = automation.CreateTrueCondition().map_err(|e| e.to_string())?;

        for hwnd in wins {
            if out.len() >= MAX_ELEMENTS {
                break;
            }
            let mut win_rect = RECT::default();
            let _ = GetWindowRect(hwnd, &mut win_rect);
            let Ok(root) = automation.ElementFromHandle(hwnd) else { continue };
            let Ok(all) = root.FindAllBuildCache(TreeScope_Descendants, &condition, &cache) else { continue };
            let len = all.Length().unwrap_or(0).min(MAX_SCAN);

            for i in 0..len {
                if out.len() >= MAX_ELEMENTS {
                    break;
                }
                let Ok(el) = all.GetElement(i) else { continue };
                let password = el.CachedIsPassword().map(|b| b.as_bool()).unwrap_or(false);
                let control_type = el.CachedControlType().unwrap_or(UIA_CustomControlTypeId).0;
                let localized = el.CachedLocalizedControlType().map(|b| b.to_string()).unwrap_or_default();
                let role = ui_control::role_for_control_type(control_type, password, is_toggle_switch(&localized));
                if !ui_control::LISTED_ROLES.contains(&role) {
                    continue;
                }

                let rect = el.CachedBoundingRectangle().unwrap_or_default();
                let width = (rect.right - rect.left) as f64;
                let height = (rect.bottom - rect.top) as f64;
                if width <= 0.0 || height <= 0.0 {
                    continue;
                }

                let name = clean_text(&el.CachedName().map(|b| b.to_string()).unwrap_or_default());
                let help = clean_text(&el.CachedHelpText().map(|b| b.to_string()).unwrap_or_default());
                let label = if !name.is_empty() {
                    name
                } else if !help.is_empty() {
                    help
                } else if password {
                    "Password".to_string()
                } else {
                    String::new()
                };
                if label.is_empty() {
                    continue;
                }

                let offscreen = el.CachedIsOffscreen().map(|b| b.as_bool()).unwrap_or(false);
                let inside = rect.right > win_rect.left
                    && rect.left < win_rect.right
                    && rect.bottom > win_rect.top
                    && rect.top < win_rect.bottom;
                let visible = !offscreen && inside;
                if !visible {
                    if offscreen_count >= MAX_OFFSCREEN {
                        continue;
                    }
                    offscreen_count += 1;
                }

                let enabled = el.CachedIsEnabled().map(|b| b.as_bool()).unwrap_or(true);
                let focused = el.CachedHasKeyboardFocus().map(|b| b.as_bool()).unwrap_or(false);

                // Never read the value of password fields!
                let value = if password {
                    None
                } else {
                    let toggle_state = if matches!(role, "checkbox" | "switch" | "toggle" | "radio") {
                        el.GetCurrentPatternAs::<IUIAutomationTogglePattern>(UIA_TogglePatternId)
                            .ok()
                            .and_then(|p| p.CurrentToggleState().ok())
                            .map(|s| s.0)
                            .or_else(|| {
                                el.GetCurrentPatternAs::<IUIAutomationSelectionItemPattern>(UIA_SelectionItemPatternId)
                                    .ok()
                                    .and_then(|p| p.CurrentIsSelected().ok())
                                    .map(|b| if b.as_bool() { 1 } else { 0 })
                            })
                    } else {
                        None
                    };
                    let raw_value = if matches!(role, "field" | "search" | "textarea" | "combobox" | "slider" | "stepper" | "popup") {
                        el.GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId)
                            .ok()
                            .and_then(|p| p.CurrentValue().ok())
                            .map(|b| clean_text(&b.to_string()))
                    } else {
                        None
                    };
                    ui_control::state_text(role, toggle_state, raw_value.as_deref())
                };

                out.push(Element {
                    role: role.to_string(),
                    label,
                    value,
                    x: rect.left as f64,
                    y: rect.top as f64,
                    width,
                    height,
                    enabled,
                    focused,
                    secure: password,
                    visible,
                });
            }
        }
    }

    Ok((win_title, out))
}

// MARK: Live point & focus queries for takeover checkpoints

fn label_at_point(x: f64, y: f64) -> Option<String> {
    if secure_desktop() {
        return None;
    }
    let automation = uia().ok()?;
    let pt = POINT { x: x.round() as i32, y: y.round() as i32 };
    unsafe {
        let el = automation.ElementFromPoint(pt).ok()?;
        let pid = el.CurrentProcessId().ok()? as u32;
        if is_blocked_pid(pid).is_some() {
            return None;
        }
        if el.CurrentIsPassword().map(|b| b.as_bool()).unwrap_or(true) {
            return Some("Password".into());
        }
        let name = clean_text(&el.CurrentName().map(|b| b.to_string()).unwrap_or_default());
        if !name.is_empty() {
            return Some(name);
        }
        let help = clean_text(&el.CurrentHelpText().map(|b| b.to_string()).unwrap_or_default());
        (!help.is_empty()).then_some(help)
    }
}

fn focused_label_for_pid(pid: u32) -> Option<String> {
    if secure_desktop() || is_blocked_pid(pid).is_some() {
        return None;
    }
    let automation = uia().ok()?;
    unsafe {
        let el = automation.GetFocusedElement().ok()?;
        let focused_pid = el.CurrentProcessId().ok()? as u32;
        if focused_pid != pid {
            return None;
        }
        if el.CurrentIsPassword().map(|b| b.as_bool()).unwrap_or(true) {
            return Some("Password".into());
        }
        let name = clean_text(&el.CurrentName().map(|b| b.to_string()).unwrap_or_default());
        if !name.is_empty() {
            return Some(name);
        }
        let help = clean_text(&el.CurrentHelpText().map(|b| b.to_string()).unwrap_or_default());
        (!help.is_empty()).then_some(help)
    }
}

fn focused_is_password() -> bool {
    let Ok(automation) = uia() else { return false };
    unsafe {
        automation
            .GetFocusedElement()
            .ok()
            .and_then(|el| el.CurrentIsPassword().ok())
            .is_some_and(|b| b.as_bool())
    }
}

/// Attempts to scroll an offscreen element into view via `IUIAutomationScrollItemPattern` and returns its new center.
fn scroll_element_into_view(pid: u32, target: &Element) -> Option<(f64, f64)> {
    let hwnd = windows_for_pid(pid).into_iter().next()?;
    let automation = uia().ok()?;
    let wanted = ui_control::normalize(&target.label);
    unsafe {
        let root = automation.ElementFromHandle(hwnd).ok()?;
        let condition = automation.CreateTrueCondition().ok()?;
        let all = root.FindAll(TreeScope_Descendants, &condition).ok()?;
        let len = all.Length().unwrap_or(0).min(MAX_SCAN);
        for i in 0..len {
            let Ok(el) = all.GetElement(i) else { continue };
            let name = clean_text(&el.CurrentName().map(|b| b.to_string()).unwrap_or_default());
            if ui_control::normalize(&name) != wanted {
                continue;
            }
            if let Ok(scroll) = el.GetCurrentPatternAs::<IUIAutomationScrollItemPattern>(UIA_ScrollItemPatternId) {
                if scroll.ScrollIntoView().is_ok() {
                    std::thread::sleep(Duration::from_millis(80));
                    if let Ok(rect) = el.CurrentBoundingRectangle() {
                        let cx = (rect.left + rect.right) as f64 / 2.0;
                        let cy = (rect.top + rect.bottom) as f64 / 2.0;
                        if rect.right > rect.left && rect.bottom > rect.top {
                            return Some((cx, cy));
                        }
                    }
                }
            }
            break;
        }
    }
    None
}

// MARK: SendInput helpers

fn virtual_coords(x: f64, y: f64) -> (i32, i32) {
    unsafe {
        let vx = GetSystemMetrics(SM_XVIRTUALSCREEN) as f64;
        let vy = GetSystemMetrics(SM_YVIRTUALSCREEN) as f64;
        let vw = (GetSystemMetrics(SM_CXVIRTUALSCREEN) - 1).max(1) as f64;
        let vh = (GetSystemMetrics(SM_CYVIRTUALSCREEN) - 1).max(1) as f64;
        let dx = ((x - vx) * 65535.0 / vw).round().clamp(0.0, 65535.0) as i32;
        let dy = ((y - vy) * 65535.0 / vh).round().clamp(0.0, 65535.0) as i32;
        (dx, dy)
    }
}

fn mouse_input(dx: i32, dy: i32, data: u32, flags: MOUSE_EVENT_FLAGS) -> INPUT {
    INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 {
            mi: MOUSEINPUT { dx, dy, mouseData: data, dwFlags: flags, time: 0, dwExtraInfo: NOOK_MARKER },
        },
    }
}

fn key_input(vk: u16, scan: u16, flags: KEYBD_EVENT_FLAGS) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT { wVk: VIRTUAL_KEY(vk), wScan: scan, dwFlags: flags, time: 0, dwExtraInfo: NOOK_MARKER },
        },
    }
}

fn send_inputs(inputs: &[INPUT]) -> Result<(), String> {
    if inputs.is_empty() {
        return Ok(());
    }
    let sent = unsafe { SendInput(inputs, std::mem::size_of::<INPUT>() as i32) };
    if sent as usize == inputs.len() {
        Ok(())
    } else {
        Err(tr(
            "Windows blokkeerde de muis- of toetsenbordinvoer (mogelijk heeft een administrator-app de focus).",
            "Windows blocked the mouse or keyboard input (an administrator app may have focus).",
        )
        .into())
    }
}

fn move_mouse(x: f64, y: f64) -> Result<(), String> {
    let _ = unsafe { SetCursorPos(x.round() as i32, y.round() as i32) };
    let (dx, dy) = virtual_coords(x, y);
    send_inputs(&[mouse_input(dx, dy, 0, MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK)])
}

fn send_click(x: f64, y: f64, right: bool, double: bool) -> Result<(), String> {
    move_mouse(x, y)?;
    std::thread::sleep(Duration::from_millis(25));
    let (down, up) = if right {
        (MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP)
    } else {
        (MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP)
    };
    send_inputs(&[mouse_input(0, 0, 0, down), mouse_input(0, 0, 0, up)])?;
    if double {
        std::thread::sleep(Duration::from_millis(45));
        send_inputs(&[mouse_input(0, 0, 0, down), mouse_input(0, 0, 0, up)])?;
    }
    Ok(())
}

fn send_drag(x1: f64, y1: f64, x2: f64, y2: f64) -> Result<(), String> {
    move_mouse(x1, y1)?;
    std::thread::sleep(Duration::from_millis(40));
    send_inputs(&[mouse_input(0, 0, 0, MOUSEEVENTF_LEFTDOWN)])?;
    for step in 1..=DRAG_STEPS {
        let t = step as f64 / DRAG_STEPS as f64;
        let x = x1 + (x2 - x1) * t;
        let y = y1 + (y2 - y1) * t;
        move_mouse(x, y)?;
        std::thread::sleep(Duration::from_millis(12));
    }
    std::thread::sleep(Duration::from_millis(30));
    send_inputs(&[mouse_input(0, 0, 0, MOUSEEVENTF_LEFTUP)])
}

fn send_scroll(x: f64, y: f64, direction: &str, amount: i64) -> Result<(), String> {
    move_mouse(x, y)?;
    std::thread::sleep(Duration::from_millis(20));
    let lines = amount.clamp(1, ui_control::MAX_SCROLL) as i32;
    let (flags, delta) = match direction {
        "up" => (MOUSEEVENTF_WHEEL, lines * WHEEL_DELTA),
        "down" => (MOUSEEVENTF_WHEEL, -lines * WHEEL_DELTA),
        "right" => (MOUSEEVENTF_HWHEEL, lines * WHEEL_DELTA),
        "left" => (MOUSEEVENTF_HWHEEL, -lines * WHEEL_DELTA),
        _ => return Err(format!("Unsupported scroll direction: {direction}")),
    };
    send_inputs(&[mouse_input(0, 0, delta as u32, flags)])
}

fn is_extended_vk(vk: u16) -> bool {
    matches!(vk, 0x21..=0x28 | 0x2D | 0x2E | 0x5B | 0x5C | 0x5D)
}

fn modifier_vk(m: Modifier) -> u16 {
    match m {
        Modifier::Ctrl => 0x11,
        Modifier::Shift => 0x10,
        Modifier::Alt => 0x12,
        Modifier::Win => 0x5B,
    }
}

fn send_key_combo(combo: &KeyCombo) -> Result<(), String> {
    let mut inputs = Vec::new();
    for &m in &combo.modifiers {
        let vk = modifier_vk(m);
        let flags = if is_extended_vk(vk) { KEYEVENTF_EXTENDEDKEY } else { KEYBD_EVENT_FLAGS(0) };
        inputs.push(key_input(vk, 0, flags));
    }
    let key_flags = if is_extended_vk(combo.code) { KEYEVENTF_EXTENDEDKEY } else { KEYBD_EVENT_FLAGS(0) };
    inputs.push(key_input(combo.code, 0, key_flags));
    inputs.push(key_input(combo.code, 0, key_flags | KEYEVENTF_KEYUP));
    for &m in combo.modifiers.iter().rev() {
        let vk = modifier_vk(m);
        let flags = if is_extended_vk(vk) {
            KEYEVENTF_EXTENDEDKEY | KEYEVENTF_KEYUP
        } else {
            KEYEVENTF_KEYUP
        };
        inputs.push(key_input(vk, 0, flags));
    }
    send_inputs(&inputs)
}

fn send_unicode_text(text: &str) -> Result<(), String> {
    let mut batch: Vec<INPUT> = Vec::with_capacity(128);
    let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
    for ch in normalized.chars() {
        if ch == '\n' {
            batch.push(key_input(0x0D, 0, KEYBD_EVENT_FLAGS(0)));
            batch.push(key_input(0x0D, 0, KEYEVENTF_KEYUP));
        } else {
            let mut buf = [0u16; 2];
            for &unit in ch.encode_utf16(&mut buf) {
                batch.push(key_input(0, unit, KEYEVENTF_UNICODE));
                batch.push(key_input(0, unit, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));
            }
        }
        if batch.len() >= 120 {
            send_inputs(&batch)?;
            batch.clear();
            std::thread::sleep(Duration::from_millis(10));
        }
    }
    send_inputs(&batch)
}

/// Fallback when Unicode typing did not land in a writable ValuePattern control (never used for password fields).
fn try_value_pattern_set(pid: u32, text: &str, replace: bool) -> bool {
    let Ok(automation) = uia() else { return false };
    unsafe {
        let Ok(el) = automation.GetFocusedElement() else { return false };
        if el.CurrentProcessId().map(|p| p as u32).unwrap_or(0) != pid {
            return false;
        }
        if el.CurrentIsPassword().map(|b| b.as_bool()).unwrap_or(true) {
            return false;
        }
        let Ok(val) = el.GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId) else {
            return false;
        };
        if val.CurrentIsReadOnly().map(|b| b.as_bool()).unwrap_or(true) {
            return false;
        }
        let current = val.CurrentValue().map(|b| b.to_string()).unwrap_or_default();
        if ui_control::typed_landed(text, &current, replace) {
            return true;
        }
        let next = if replace { text.to_string() } else { format!("{current}{text}") };
        val.SetValue(&BSTR::from(next)).is_ok()
    }
}

// MARK: Step execution

fn resolve_point(pid: u32, target: Option<&Element>, x: Option<f64>, y: Option<f64>) -> Result<(f64, f64), String> {
    if let Some(el) = target {
        if !el.visible {
            if let Some(pt) = scroll_element_into_view(pid, el) {
                return Ok(pt);
            }
        }
        return Ok((el.center_x(), el.center_y()));
    }
    x.zip(y).ok_or_else(|| "Target coordinates are missing.".to_string())
}

fn ensure_point_owned(x: f64, y: f64, pid: u32) -> Result<(), String> {
    if owns_point(x, y, pid) {
        return Ok(());
    }
    Err(tr(
        "Dat punt behoort nu niet meer tot het venster van de app; lees het venster opnieuw.",
        "That point no longer belongs to the app's window; read the window again.",
    )
    .into())
}

fn ensure_foreground(pid: u32, hwnd: HWND) -> Result<(), String> {
    if foreground_pid() != Some(pid) {
        bring_to_front(hwnd);
    }
    if foreground_pid() != Some(pid) {
        return Err(tr(
            "De app kon niet naar de voorgrond worden gehaald.",
            "The app could not be brought to the front.",
        )
        .into());
    }
    Ok(())
}

fn perform_step(pid: u32, step: &Step, target: Option<&Element>, to: Option<&Element>) -> Result<String, String> {
    ensure_allowed_process(pid)?;
    let step_errs = ui_control::step_problems(step);
    if !step_errs.is_empty() {
        return Err(step_errs.join("; "));
    }

    // Open a Windows Settings page (`ms-settings:...`) without needing a pre-existing window first.
    if step.action == Action::Open {
        if let Some(url) = step.url.as_deref().map(str::trim).filter(|u| !u.is_empty()) {
            std::process::Command::new("explorer.exe")
                .arg(url)
                .spawn()
                .map_err(|e| format!("Could not open {url}: {e}"))?;
            std::thread::sleep(Duration::from_millis(350));
            return Ok(ui_control::step_summary(step));
        }
    }

    if step.action == Action::Wait {
        let secs = step.seconds.unwrap_or(1.0).clamp(0.1, ui_control::MAX_WAIT);
        std::thread::sleep(Duration::from_secs_f64(secs));
        return Ok(ui_control::step_summary(step));
    }

    let hwnd = windows_for_pid(pid)
        .into_iter()
        .next()
        .ok_or_else(|| tr("Geen zichtbaar venster gevonden voor deze app.", "No visible window found for this app.").to_string())?;
    bring_to_front(hwnd);

    match step.action {
        Action::Open | Action::Wait => Ok(ui_control::step_summary(step)),
        Action::Click | Action::DoubleClick | Action::RightClick => {
            if let Some(el) = target {
                if !el.enabled {
                    return Err(trf(
                        "“{label}” is uitgeschakeld.",
                        "“{label}” is disabled.",
                        &[("label", &el.label)],
                    ));
                }
            }
            let (x, y) = resolve_point(pid, target, step.x, step.y)?;
            ensure_point_owned(x, y, pid)?;
            send_click(x, y, step.action == Action::RightClick, step.action == Action::DoubleClick)?;
            Ok(ui_control::step_summary(step))
        }
        Action::Hover => {
            let (x, y) = resolve_point(pid, target, step.x, step.y)?;
            ensure_point_owned(x, y, pid)?;
            move_mouse(x, y)?;
            Ok(ui_control::step_summary(step))
        }
        Action::Drag => {
            let (x1, y1) = resolve_point(pid, target, step.x, step.y)?;
            let (x2, y2) = resolve_point(pid, to, step.to_x, step.to_y)?;
            ensure_point_owned(x1, y1, pid)?;
            ensure_point_owned(x2, y2, pid)?;
            send_drag(x1, y1, x2, y2)?;
            Ok(ui_control::step_summary(step))
        }
        Action::Scroll => {
            let (x, y) = if target.is_some() || (step.x.is_some() && step.y.is_some()) {
                resolve_point(pid, target, step.x, step.y)?
            } else {
                let mut rect = RECT::default();
                unsafe { GetWindowRect(hwnd, &mut rect) }.map_err(|e| e.to_string())?;
                ((rect.left + rect.right) as f64 / 2.0, (rect.top + rect.bottom) as f64 / 2.0)
            };
            ensure_point_owned(x, y, pid)?;
            let dir = step.direction.as_deref().unwrap_or("down");
            let amount = step.amount.unwrap_or(5);
            send_scroll(x, y, dir, amount)?;
            Ok(ui_control::step_summary(step))
        }
        Action::Type => {
            let text = step.text.as_deref().unwrap_or("");
            if takeover::contains_high_risk_number(text) {
                return Err(tr(
                    "Nook typt nooit betaalkaart- of burgerservicenummers.",
                    "Nook never types card or social security numbers.",
                )
                .into());
            }
            if let Some(el) = target {
                if el.secure {
                    return Err(tr(
                        "Nook typt nooit in wachtwoordvelden.",
                        "Nook never types into password fields.",
                    )
                    .into());
                }
                if !el.enabled {
                    return Err(trf(
                        "“{label}” is uitgeschakeld.",
                        "“{label}” is disabled.",
                        &[("label", &el.label)],
                    ));
                }
                let (x, y) = resolve_point(pid, Some(el), None, None)?;
                ensure_point_owned(x, y, pid)?;
                send_click(x, y, false, false)?;
                std::thread::sleep(Duration::from_millis(60));
            }
            ensure_foreground(pid, hwnd)?;
            if focused_is_password() {
                return Err(tr(
                    "Nook typt nooit in wachtwoordvelden.",
                    "Nook never types into password fields.",
                )
                .into());
            }
            if step.replace {
                if let Some(select_all) = ui_control::parse_keys("ctrl+a") {
                    send_key_combo(&select_all)?;
                    std::thread::sleep(Duration::from_millis(30));
                }
                if let Some(bksp) = ui_control::parse_keys("backspace") {
                    send_key_combo(&bksp)?;
                    std::thread::sleep(Duration::from_millis(20));
                }
            }
            send_unicode_text(text)?;
            std::thread::sleep(Duration::from_millis(60));
            if !text.contains(['\n', '\r']) {
                let _ = try_value_pattern_set(pid, text, step.replace);
            }
            Ok(ui_control::step_summary(step))
        }
        Action::Key => {
            let raw = step.keys.as_deref().unwrap_or("");
            let combo = ui_control::parse_keys(raw).ok_or_else(|| format!("Unknown key combination: {raw}"))?;
            if let Some(reason) = ui_control::forbidden(&combo) {
                return Err(format!("Not run: {reason}."));
            }
            ensure_foreground(pid, hwnd)?;
            send_key_combo(&combo)?;
            Ok(ui_control::step_summary(step))
        }
    }
}
