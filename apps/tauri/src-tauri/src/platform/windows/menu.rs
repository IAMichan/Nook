//! Reads and invokes an app's menu bar commands on Windows: classic Win32 `HMENU` silently first (when present), then
//! UI Automation (`IUIAutomation` `MenuBar` / `MenuItem` / `ExpandCollapse` / `Invoke` patterns) for modern WinUI,
//! Electron, Qt, WPF and browser windows.

use std::time::Duration;

use nook_core::brain::app_menu;
use nook_core::platform::MenuCommandOutcome;
use windows::core::{BOOL, PWSTR};
use windows::Win32::Foundation::{HWND, LPARAM, WPARAM};
use windows::Win32::System::Com::{CoCreateInstance, CLSCTX_INPROC_SERVER};
use windows::Win32::System::Variant::VARIANT;
use windows::Win32::UI::Accessibility::*;
use windows::Win32::UI::WindowsAndMessaging::{
    GetForegroundWindow, GetMenu, GetMenuItemCount, GetMenuItemInfoW, GetWindowLongW, GetWindowThreadProcessId, IsIconic, IsWindowVisible,
    PostMessageW, SendMessageW, SetForegroundWindow, ShowWindow, GWL_EXSTYLE, HMENU, MENUITEMINFOW, MFS_DISABLED, MFT_SEPARATOR,
    MIIM_FTYPE, MIIM_ID, MIIM_STATE, MIIM_STRING, MIIM_SUBMENU, SW_RESTORE, WM_COMMAND, WM_INITMENUPOPUP, WS_EX_TOOLWINDOW,
};

use super::screen::{cloaked, com, title, top_windows};

/// Finds the frontmost/topmost visible window of process `pid`.
fn target_window(pid: u32) -> Option<HWND> {
    let front = unsafe { GetForegroundWindow() };
    let candidates = top_windows().into_iter().filter(|&hwnd| unsafe {
        if !IsWindowVisible(hwnd).as_bool() || cloaked(hwnd) {
            return false;
        }
        if (GetWindowLongW(hwnd, GWL_EXSTYLE) as u32) & WS_EX_TOOLWINDOW.0 != 0 {
            return false;
        }
        let mut win_pid = 0u32;
        GetWindowThreadProcessId(hwnd, Some(&mut win_pid));
        win_pid == pid && !title(hwnd).is_empty()
    });
    let list: Vec<HWND> = candidates.collect();
    if let Some(&fg) = list.iter().find(|&&h| h == front) {
        return Some(fg);
    }
    list.into_iter().next()
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

// MARK: - Classic Win32 HMENU

fn menu_item_info(hmenu: HMENU, pos: u32) -> Option<(MENUITEMINFOW, String)> {
    unsafe {
        let mut info = MENUITEMINFOW {
            cbSize: std::mem::size_of::<MENUITEMINFOW>() as u32,
            fMask: MIIM_FTYPE | MIIM_STATE | MIIM_SUBMENU | MIIM_ID | MIIM_STRING,
            ..Default::default()
        };
        if GetMenuItemInfoW(hmenu, pos, true, &mut info).is_err() {
            return None;
        }
        let mut label = String::new();
        if info.cch > 0 {
            let mut buf = vec![0u16; info.cch as usize + 1];
            info.fMask = MIIM_STRING;
            info.dwTypeData = PWSTR(buf.as_mut_ptr());
            info.cch += 1;
            if GetMenuItemInfoW(hmenu, pos, true, &mut info).is_ok() {
                label = String::from_utf16_lossy(&buf[..info.cch as usize]);
            }
        }
        Some((info, app_menu::clean_label(&label)))
    }
}

fn walk_hmenu(hwnd: HWND, hmenu: HMENU, prefix: &[String], depth: usize, out: &mut Vec<String>) {
    if depth >= app_menu::MAX_DEPTH {
        return;
    }
    let count = unsafe { GetMenuItemCount(Some(hmenu)) };
    if count <= 0 {
        return;
    }
    for i in 0..count as u32 {
        let Some((info, label)) = menu_item_info(hmenu, i) else { continue };
        if (info.fType & MFT_SEPARATOR).0 != 0 {
            continue;
        }
        if (info.fState & MFS_DISABLED).0 != 0 || label.is_empty() {
            continue;
        }
        let mut next = prefix.to_vec();
        next.push(label);
        if !info.hSubMenu.is_invalid() && !info.hSubMenu.0.is_null() {
            unsafe {
                let _ = SendMessageW(hwnd, WM_INITMENUPOPUP, Some(WPARAM(info.hSubMenu.0 as usize)), Some(LPARAM(i as isize)));
            }
            if depth + 1 < app_menu::MAX_DEPTH {
                walk_hmenu(hwnd, info.hSubMenu, &next, depth + 1, out);
            }
        } else if depth >= 1 {
            out.push(next.join(" > "));
        }
    }
}

fn click_hmenu(hwnd: HWND, hmenu: HMENU, path: &[String]) -> Option<Result<MenuCommandOutcome, String>> {
    let mut current = hmenu;
    for (idx, segment) in path.iter().enumerate() {
        let count = unsafe { GetMenuItemCount(Some(current)) };
        if count <= 0 {
            return None;
        }
        let mut matched: Option<(u32, MENUITEMINFOW)> = None;
        for i in 0..count as u32 {
            let Some((info, label)) = menu_item_info(current, i) else { continue };
            if (info.fType & MFT_SEPARATOR).0 != 0 || label.is_empty() {
                continue;
            }
            if app_menu::label_matches(&label, segment) {
                matched = Some((i, info));
                break;
            }
        }
        let (pos, info) = matched?;
        let last = idx + 1 == path.len();
        if last {
            if (info.fState & MFS_DISABLED).0 != 0 {
                return Some(Ok(MenuCommandOutcome::Disabled));
            }
            if info.wID == 0 {
                return None;
            }
            let res = unsafe { PostMessageW(Some(hwnd), WM_COMMAND, WPARAM(info.wID as usize), LPARAM(0)) };
            return Some(res.map(|_| MenuCommandOutcome::Done).map_err(|e| e.to_string()));
        }
        if info.hSubMenu.is_invalid() || info.hSubMenu.0.is_null() {
            return None;
        }
        unsafe {
            let _ = SendMessageW(hwnd, WM_INITMENUPOPUP, Some(WPARAM(info.hSubMenu.0 as usize)), Some(LPARAM(pos as isize)));
        }
        current = info.hSubMenu;
    }
    None
}

// MARK: - UI Automation

fn control_type_condition(automation: &IUIAutomation, kind: UIA_CONTROLTYPE_ID) -> windows::core::Result<IUIAutomationCondition> {
    let var = VARIANT::from(kind.0);
    unsafe { automation.CreatePropertyCondition(UIA_ControlTypePropertyId, &var) }
}

fn is_system_menu_bar(bar: &IUIAutomationElement) -> bool {
    unsafe {
        if let Ok(id) = bar.CurrentAutomationId() {
            if id.to_string().eq_ignore_ascii_case("SystemMenuBar") {
                return true;
            }
        }
        if let Ok(name) = bar.CurrentName() {
            if name.to_string().eq_ignore_ascii_case("System") {
                return true;
            }
        }
        false
    }
}

fn uia_menu_bars(automation: &IUIAutomation, root: &IUIAutomationElement) -> Vec<IUIAutomationElement> {
    let Ok(cond) = control_type_condition(automation, UIA_MenuBarControlTypeId) else { return vec![] };
    let Ok(all) = (unsafe { root.FindAll(TreeScope_Descendants, &cond) }) else { return vec![] };
    let len = unsafe { all.Length().unwrap_or(0) };
    (0..len).filter_map(|i| unsafe { all.GetElement(i).ok() }).filter(|bar| !is_system_menu_bar(bar)).collect()
}

fn uia_name(elem: &IUIAutomationElement) -> String {
    unsafe { elem.CurrentName().map(|b| app_menu::clean_label(&b.to_string())).unwrap_or_default() }
}

fn uia_enabled(elem: &IUIAutomationElement) -> bool {
    unsafe { elem.CurrentIsEnabled().map(|b| b.as_bool()).unwrap_or(true) }
}

fn uia_children(automation: &IUIAutomation, parent: &IUIAutomationElement, kind: UIA_CONTROLTYPE_ID) -> Vec<IUIAutomationElement> {
    let Ok(cond) = control_type_condition(automation, kind) else { return vec![] };
    let Ok(all) = (unsafe { parent.FindAll(TreeScope_Children, &cond) }) else { return vec![] };
    let len = unsafe { all.Length().unwrap_or(0) };
    (0..len).filter_map(|i| unsafe { all.GetElement(i).ok() }).collect()
}

fn uia_descendants(automation: &IUIAutomation, parent: &IUIAutomationElement, kind: UIA_CONTROLTYPE_ID) -> Vec<IUIAutomationElement> {
    let Ok(cond) = control_type_condition(automation, kind) else { return vec![] };
    let Ok(all) = (unsafe { parent.FindAll(TreeScope_Descendants, &cond) }) else { return vec![] };
    let len = unsafe { all.Length().unwrap_or(0) };
    (0..len).filter_map(|i| unsafe { all.GetElement(i).ok() }).collect()
}

/// Direct `MenuItem` children of an expanded item or its nested `Menu` popup, plus any popup `Menu` hosted directly
/// under `root` or the desktop for `pid`.
fn uia_popup_items(
    automation: &IUIAutomation,
    root: &IUIAutomationElement,
    pid: u32,
    parent: &IUIAutomationElement,
) -> Vec<IUIAutomationElement> {
    let direct = uia_children(automation, parent, UIA_MenuItemControlTypeId);
    if !direct.is_empty() {
        return direct;
    }
    for menu in uia_children(automation, parent, UIA_MenuControlTypeId) {
        let items = uia_children(automation, &menu, UIA_MenuItemControlTypeId);
        if !items.is_empty() {
            return items;
        }
    }
    for menu in uia_descendants(automation, root, UIA_MenuControlTypeId) {
        let items = uia_children(automation, &menu, UIA_MenuItemControlTypeId);
        if !items.is_empty() {
            return items;
        }
    }
    if let Ok(desktop) = unsafe { automation.GetRootElement() } {
        let pid_var = VARIANT::from(pid as i32);
        if let (Ok(pid_cond), Ok(menu_cond)) = (
            unsafe { automation.CreatePropertyCondition(UIA_ProcessIdPropertyId, &pid_var) },
            control_type_condition(automation, UIA_MenuControlTypeId),
        ) {
            if let Ok(and_cond) = unsafe { automation.CreateAndCondition(&pid_cond, &menu_cond) } {
                if let Ok(menus) = unsafe { desktop.FindAll(TreeScope_Children, &and_cond) } {
                    let len = unsafe { menus.Length().unwrap_or(0) };
                    for i in 0..len {
                        if let Ok(menu) = unsafe { menus.GetElement(i) } {
                            let items = uia_children(automation, &menu, UIA_MenuItemControlTypeId);
                            if !items.is_empty() {
                                return items;
                            }
                        }
                    }
                }
            }
        }
    }
    vec![]
}

fn expand_element(elem: &IUIAutomationElement) -> Option<IUIAutomationExpandCollapsePattern> {
    let pattern = unsafe { elem.GetCurrentPatternAs::<IUIAutomationExpandCollapsePattern>(UIA_ExpandCollapsePatternId).ok()? };
    if unsafe { pattern.CurrentExpandCollapseState().ok() } != Some(ExpandCollapseState_Expanded) {
        unsafe { pattern.Expand().ok()? };
        std::thread::sleep(Duration::from_millis(45));
    }
    Some(pattern)
}

fn list_uia(hwnd: HWND, pid: u32) -> windows::core::Result<Vec<String>> {
    com();
    unsafe {
        let automation: IUIAutomation = CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER)?;
        let root = automation.ElementFromHandle(hwnd)?;
        let bars = uia_menu_bars(&automation, &root);
        let mut out = Vec::new();
        for bar in bars {
            for top in uia_children(&automation, &bar, UIA_MenuItemControlTypeId) {
                let top_name = uia_name(&top);
                if top_name.is_empty() || !uia_enabled(&top) {
                    continue;
                }
                let mut children = uia_children(&automation, &top, UIA_MenuItemControlTypeId);
                let mut expanded = None;
                if children.is_empty() {
                    expanded = expand_element(&top);
                    if expanded.is_some() {
                        children = uia_popup_items(&automation, &root, pid, &top);
                    }
                }
                for item in children {
                    let item_name = uia_name(&item);
                    if item_name.is_empty() || !uia_enabled(&item) {
                        continue;
                    }
                    let subitems = uia_children(&automation, &item, UIA_MenuItemControlTypeId);
                    if subitems.is_empty() {
                        out.push(format!("{top_name} > {item_name}"));
                    } else {
                        for sub in subitems {
                            let sub_name = uia_name(&sub);
                            if !sub_name.is_empty() && uia_enabled(&sub) {
                                out.push(format!("{top_name} > {item_name} > {sub_name}"));
                            }
                        }
                    }
                }
                if let Some(pattern) = expanded {
                    let _ = pattern.Collapse();
                }
            }
        }
        Ok(out)
    }
}

fn invoke_uia_item(elem: &IUIAutomationElement) -> Result<MenuCommandOutcome, String> {
    if !uia_enabled(elem) {
        return Ok(MenuCommandOutcome::Disabled);
    }
    unsafe {
        if let Ok(pattern) = elem.GetCurrentPatternAs::<IUIAutomationInvokePattern>(UIA_InvokePatternId) {
            return pattern.Invoke().map(|_| MenuCommandOutcome::Done).map_err(|e| e.to_string());
        }
        if let Ok(pattern) = elem.GetCurrentPatternAs::<IUIAutomationTogglePattern>(UIA_TogglePatternId) {
            return pattern.Toggle().map(|_| MenuCommandOutcome::Done).map_err(|e| e.to_string());
        }
        if let Ok(pattern) = elem.GetCurrentPatternAs::<IUIAutomationSelectionItemPattern>(UIA_SelectionItemPatternId) {
            return pattern.Select().map(|_| MenuCommandOutcome::Done).map_err(|e| e.to_string());
        }
    }
    Err("Menu item cannot be invoked.".into())
}

fn click_uia(hwnd: HWND, pid: u32, path: &[String]) -> windows::core::Result<Result<MenuCommandOutcome, String>> {
    com();
    unsafe {
        let automation: IUIAutomation = CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER)?;
        let root = automation.ElementFromHandle(hwnd)?;
        let mut top_match = None;
        for bar in uia_menu_bars(&automation, &root) {
            if let Some(found) = uia_children(&automation, &bar, UIA_MenuItemControlTypeId)
                .into_iter()
                .find(|el| app_menu::label_matches(&uia_name(el), &path[0]))
            {
                top_match = Some(found);
                break;
            }
        }
        let Some(mut current) = top_match else {
            return Ok(Ok(MenuCommandOutcome::NotFound));
        };
        let mut expanded_stack: Vec<IUIAutomationExpandCollapsePattern> = Vec::new();
        for segment in &path[1..] {
            let mut items = uia_children(&automation, &current, UIA_MenuItemControlTypeId);
            if !items.iter().any(|el| app_menu::label_matches(&uia_name(el), segment)) {
                if let Some(pattern) = expand_element(&current) {
                    expanded_stack.push(pattern);
                    std::thread::sleep(Duration::from_millis(30));
                    items = uia_popup_items(&automation, &root, pid, &current);
                }
            }
            let Some(next) = items.into_iter().find(|el| app_menu::label_matches(&uia_name(el), segment)) else {
                for pattern in expanded_stack.into_iter().rev() {
                    let _ = pattern.Collapse();
                }
                return Ok(Ok(MenuCommandOutcome::NotFound));
            };
            current = next;
        }
        let result = invoke_uia_item(&current);
        if matches!(result, Ok(MenuCommandOutcome::Disabled)) {
            for pattern in expanded_stack.into_iter().rev() {
                let _ = pattern.Collapse();
            }
        }
        Ok(result)
    }
}

pub fn list(pid: u32) -> Result<Vec<String>, String> {
    let Some(hwnd) = target_window(pid) else {
        return Ok(vec![]);
    };
    let hmenu = unsafe { GetMenu(hwnd) };
    if !hmenu.is_invalid() && !hmenu.0.is_null() {
        let mut out = Vec::new();
        walk_hmenu(hwnd, hmenu, &[], 0, &mut out);
        if !out.is_empty() {
            return Ok(out);
        }
    }
    list_uia(hwnd, pid).map_err(|e| format!("Menu could not be read: {e}"))
}

pub fn click(pid: u32, path: &[String]) -> Result<MenuCommandOutcome, String> {
    if path.is_empty() {
        return Ok(MenuCommandOutcome::NotFound);
    }
    let Some(hwnd) = target_window(pid) else {
        return Ok(MenuCommandOutcome::NotFound);
    };
    bring_to_front(hwnd);
    let hmenu = unsafe { GetMenu(hwnd) };
    if !hmenu.is_invalid() && !hmenu.0.is_null() {
        if let Some(outcome) = click_hmenu(hwnd, hmenu, path) {
            return outcome;
        }
    }
    click_uia(hwnd, pid, path).map_err(|e| format!("Menu command failed: {e}"))?
}

// Keep unused BOOL import suppressed cleanly if unused on some feature sets.
const _: fn() -> BOOL = || BOOL(1);
