//! Reading the user's open browser tab on Windows through UI Automation (`IUIAutomation`): inspects running
//! browsers in z-order (even when Nook's chat is in front), wakes Chromium's accessibility tree when needed, reads
//! the active tab's title, address bar / document URL and page text, or finds a background tab by name.

use std::time::Duration;

use nook_core::brain::open_browser_tab::{self, BrowserSpec, BrowserTab, BrowserTabResult, TEXT_LIMIT};
use windows::core::BSTR;
use windows::Win32::Foundation::HWND;
use windows::Win32::System::Com::{CoCreateInstance, CLSCTX_INPROC_SERVER};
use windows::Win32::System::Variant::VARIANT;
use windows::Win32::UI::Accessibility::*;

use super::screen::com;

/// Metadata for a visible top-level browser window passed from `WindowsScreen`.
pub(super) struct BrowserWindow {
    pub hwnd: HWND,
    pub spec: &'static BrowserSpec,
    pub title: String,
}

pub(super) fn read_browser_tab<F>(
    windows: Vec<BrowserWindow>,
    browser_filter: Option<&str>,
    tab_query: Option<&str>,
    mut fallback_read: F,
) -> BrowserTabResult
where
    F: FnMut(HWND, usize) -> String,
{
    let (parsed_browser, parsed_tab) = open_browser_tab::parse_query(tab_query.unwrap_or(""), browser_filter.unwrap_or(""));
    let running_all: Vec<String> = unique_names(&windows);
    if running_all.is_empty() {
        return BrowserTabResult::NotFound { running: vec![] };
    }

    let candidates: Vec<&BrowserWindow> = match parsed_browser {
        Some(spec) => windows.iter().filter(|w| w.spec.name == spec.name).collect(),
        None => {
            if browser_filter.is_some_and(|s| !s.trim().is_empty()) {
                return BrowserTabResult::NotFound { running: running_all };
            }
            windows.iter().collect()
        }
    };

    if candidates.is_empty() {
        return BrowserTabResult::NotFound { running: running_all };
    }

    let queried_names =
        if parsed_browser.is_some() { candidates.iter().map(|w| w.spec.name.to_string()).collect::<Vec<_>>() } else { running_all.clone() };

    com();
    let automation: Option<IUIAutomation> = unsafe { CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER).ok() };

    for win in &candidates {
        let mut active_title = open_browser_tab::clean_tab_title(&win.title, win.spec.name);
        let mut url = String::new();
        let mut doc_text = String::new();

        if let Some(auto) = automation.as_ref() {
            let inspect = inspect_window(auto, win.hwnd);
            if !inspect.url.is_empty() {
                url = inspect.url;
            }
            if !inspect.doc_title.is_empty() && active_title.is_empty() {
                active_title = inspect.doc_title;
            }
            doc_text = inspect.text;
        }

        if let Some(query) = parsed_tab.as_deref() {
            let active_matches =
                open_browser_tab::tab_matches(&active_title, &url, query) || open_browser_tab::tab_matches(&win.title, &url, query);
            if !active_matches {
                if let Some(auto) = automation.as_ref() {
                    if let Some(bg_title) = find_background_tab(auto, win.hwnd, query) {
                        return BrowserTabResult::Found(BrowserTab {
                            browser: win.spec.name.to_string(),
                            title: bg_title,
                            url: String::new(),
                            visible: false,
                            text: String::new(),
                        });
                    }
                }
                continue;
            }
        }

        // Chromium builds its UIA document tree lazily when first queried; wake and retry once if empty.
        if doc_text.trim().is_empty() {
            if let Some(auto) = automation.as_ref() {
                std::thread::sleep(Duration::from_millis(350));
                let retry = inspect_window(auto, win.hwnd);
                if url.is_empty() && !retry.url.is_empty() {
                    url = retry.url;
                }
                if active_title.is_empty() && !retry.doc_title.is_empty() {
                    active_title = retry.doc_title;
                }
                doc_text = retry.text;
            }
        }

        if doc_text.trim().chars().count() < 20 {
            let fb = fallback_read(win.hwnd, TEXT_LIMIT);
            if fb.trim().chars().count() > doc_text.trim().chars().count() {
                doc_text = fb;
            }
        }

        if active_title.is_empty() && url.is_empty() && doc_text.trim().is_empty() {
            continue;
        }

        return BrowserTabResult::Found(BrowserTab {
            browser: win.spec.name.to_string(),
            title: active_title,
            url,
            visible: true,
            text: open_browser_tab::cap_text(&doc_text),
        });
    }

    let mut deduped = queried_names;
    deduped.sort();
    deduped.dedup();
    BrowserTabResult::NotFound { running: deduped }
}

fn unique_names(windows: &[BrowserWindow]) -> Vec<String> {
    let mut names = Vec::new();
    for w in windows {
        let s = w.spec.name.to_string();
        if !names.contains(&s) {
            names.push(s);
        }
    }
    names
}

struct WindowInspect {
    url: String,
    doc_title: String,
    text: String,
}

fn inspect_window(auto: &IUIAutomation, hwnd: HWND) -> WindowInspect {
    let mut out = WindowInspect { url: String::new(), doc_title: String::new(), text: String::new() };
    unsafe {
        let Ok(root) = auto.ElementFromHandle(hwnd) else { return out };
        if let Ok(doc_cond) = auto.CreatePropertyCondition(UIA_ControlTypePropertyId, &VARIANT::from(UIA_DocumentControlTypeId.0)) {
            if let Ok(doc) = root.FindFirst(TreeScope_Descendants, &doc_cond) {
                if let Ok(pattern) = doc.GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId) {
                    if let Ok(val) = pattern.CurrentValue() {
                        out.url = open_browser_tab::normalize_url(&val.to_string());
                    }
                }
                if let Ok(name) = doc.CurrentName() {
                    out.doc_title = name.to_string().trim().to_string();
                }
                out.text = read_document_text(auto, &doc, TEXT_LIMIT);
            }
        }
        if out.url.is_empty() {
            out.url = read_address_bar_url(auto, &root);
        }
    }
    out
}

unsafe fn read_address_bar_url(auto: &IUIAutomation, root: &IUIAutomationElement) -> String {
    let Ok(edit_cond) = auto.CreatePropertyCondition(UIA_ControlTypePropertyId, &VARIANT::from(UIA_EditControlTypeId.0)) else {
        return String::new();
    };
    let Ok(cache) = auto.CreateCacheRequest() else { return String::new() };
    let _ = cache.AddProperty(UIA_NamePropertyId);
    let _ = cache.AddProperty(UIA_AutomationIdPropertyId);
    let Ok(edits) = root.FindAllBuildCache(TreeScope_Descendants, &edit_cond, &cache) else {
        return String::new();
    };
    let count = edits.Length().unwrap_or(0).min(30);
    let mut fallback_url = String::new();
    for i in 0..count {
        let Ok(el) = edits.GetElement(i) else { continue };
        let name = el.CachedName().unwrap_or_default().to_string().to_lowercase();
        let aid = el.CachedAutomationId().unwrap_or_default().to_string().to_lowercase();
        let is_address_bar = ["address", "adres", "url", "location", "omnibox", "urlbar", "search or enter", "zoek"]
            .iter()
            .any(|k| name.contains(k) || aid.contains(k));
        let Ok(pattern) = el.GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId) else { continue };
        let Ok(val) = pattern.CurrentValue() else { continue };
        let normalized = open_browser_tab::normalize_url(&val.to_string());
        if normalized.is_empty() {
            continue;
        }
        if is_address_bar {
            return normalized;
        }
        if fallback_url.is_empty() {
            fallback_url = normalized;
        }
    }
    fallback_url
}

unsafe fn read_document_text(auto: &IUIAutomation, doc: &IUIAutomationElement, limit: usize) -> String {
    if let Ok(pattern) = doc.GetCurrentPatternAs::<IUIAutomationTextPattern>(UIA_TextPatternId) {
        if let Ok(text) = pattern.DocumentRange().and_then(|r| r.GetText(limit as i32)) {
            let s = text.to_string();
            if s.trim().chars().count() >= 20 {
                return open_browser_tab::cap_text(&s);
            }
        }
    }
    let Ok(true_cond) = auto.CreateTrueCondition() else { return String::new() };
    let Ok(cache) = auto.CreateCacheRequest() else { return String::new() };
    let _ = cache.AddProperty(UIA_NamePropertyId);
    let _ = cache.AddProperty(UIA_ControlTypePropertyId);
    let _ = cache.AddProperty(UIA_IsPasswordPropertyId);
    let Ok(all) = doc.FindAllBuildCache(TreeScope_Descendants, &true_cond, &cache) else {
        return String::new();
    };
    let skip = [
        UIA_MenuBarControlTypeId,
        UIA_MenuControlTypeId,
        UIA_MenuItemControlTypeId,
        UIA_ToolBarControlTypeId,
        UIA_ScrollBarControlTypeId,
        UIA_TitleBarControlTypeId,
    ];
    let mut lines: Vec<String> = Vec::new();
    let mut count = 0usize;
    let total = all.Length().unwrap_or(0).min(4500);
    for i in 0..total {
        if count >= limit {
            break;
        }
        let Ok(element) = all.GetElement(i) else { continue };
        if element.CachedIsPassword().map(|b| b.as_bool()).unwrap_or(false) {
            continue;
        }
        let kind = element.CachedControlType().unwrap_or(UIA_CustomControlTypeId);
        if skip.contains(&kind) {
            continue;
        }
        let name: BSTR = element.CachedName().unwrap_or_default();
        let clean = name.to_string().trim().to_string();
        if !clean.is_empty() && lines.last() != Some(&clean) {
            count += clean.chars().count() + 1;
            lines.push(clean);
        }
    }
    lines.join("\n")
}

fn find_background_tab(auto: &IUIAutomation, hwnd: HWND, query: &str) -> Option<String> {
    unsafe {
        let root = auto.ElementFromHandle(hwnd).ok()?;
        let tab_cond = auto.CreatePropertyCondition(UIA_ControlTypePropertyId, &VARIANT::from(UIA_TabItemControlTypeId.0)).ok()?;
        let cache = auto.CreateCacheRequest().ok()?;
        let _ = cache.AddProperty(UIA_NamePropertyId);
        let tabs = root.FindAllBuildCache(TreeScope_Descendants, &tab_cond, &cache).ok()?;
        let count = tabs.Length().unwrap_or(0).min(200);
        for i in 0..count {
            let Ok(item) = tabs.GetElement(i) else { continue };
            let name = item.CachedName().unwrap_or_default().to_string().trim().to_string();
            if name.is_empty() {
                continue;
            }
            if !open_browser_tab::tab_matches(&name, "", query) {
                continue;
            }
            let selected = item
                .GetCurrentPatternAs::<IUIAutomationSelectionItemPattern>(UIA_SelectionItemPatternId)
                .ok()
                .and_then(|p| p.CurrentIsSelected().ok())
                .is_some_and(|b| b.as_bool());
            if !selected {
                return Some(name);
            }
        }
    }
    None
}
