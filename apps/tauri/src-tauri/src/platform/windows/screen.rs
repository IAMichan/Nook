//! Scherm lezen op Windows: UI Automation (de laag die Verteller gebruikt) voor de tekst van vensters, ook als ze
//! achter andere vensters staan; als een app daar niets geeft, tekstherkenning (`Windows.Media.Ocr`) op een
//! schermafbeelding van het venster. Alles op deze computer.

use std::collections::BTreeMap;

use nook_core::platform::{Capture, RunningApp, ScreenReader, SeenWindow, WindowText};
use nook_core::services::{fuzzy, screen};
use windows::core::{BOOL, BSTR, HSTRING, PWSTR};
use windows::Graphics::Imaging::{BitmapAlphaMode, BitmapPixelFormat, SoftwareBitmap};
use windows::Media::Ocr::OcrEngine;
use windows::Security::Cryptography::CryptographicBuffer;
use windows::Win32::Foundation::{CloseHandle, HWND, LPARAM, RECT};
use windows::Win32::Graphics::Dwm::{DwmGetWindowAttribute, DWMWA_CLOAKED};
use windows::Win32::Graphics::Gdi::{
    BitBlt, CreateCompatibleBitmap, CreateCompatibleDC, DeleteDC, DeleteObject, GetDC, GetDIBits, ReleaseDC, SelectObject, BITMAPINFO,
    BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS, HBITMAP, HDC, SRCCOPY,
};
use windows::Win32::Storage::FileSystem::{GetFileVersionInfoSizeW, GetFileVersionInfoW, VerQueryValueW};
use windows::Win32::Storage::Xps::{PrintWindow, PRINT_WINDOW_FLAGS};
use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED};
use windows::Win32::System::SystemInformation::GetTickCount;
use windows::Win32::System::Threading::{OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION};
use windows::Win32::UI::Accessibility::*;
use windows::Win32::UI::Input::KeyboardAndMouse::{GetLastInputInfo, LASTINPUTINFO};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GetForegroundWindow, GetSystemMetrics, GetWindowLongW, GetWindowRect, GetWindowTextLengthW, GetWindowTextW,
    GetWindowThreadProcessId, IsIconic, IsWindowVisible, GWL_EXSTYLE, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN,
    SM_YVIRTUALSCREEN, WS_EX_TOOLWINDOW,
};

use crate::platform::imaging;

/// COM in deze draad (UI Automation, geluid); een tweede keer is onschuldig.
pub fn com() {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
    }
}

#[derive(Debug, Clone)]
struct Win {
    hwnd: isize,
    title: String,
    exe: String,
    name: String,
    pid: u32,
    rect: RECT,
}

unsafe extern "system" fn collect(hwnd: HWND, lparam: LPARAM) -> BOOL {
    let list = &mut *(lparam.0 as *mut Vec<HWND>);
    list.push(hwnd);
    BOOL(1)
}

pub(super) fn top_windows() -> Vec<HWND> {
    let mut list: Vec<HWND> = Vec::new();
    unsafe {
        let _ = EnumWindows(Some(collect), LPARAM(&mut list as *mut Vec<HWND> as isize));
    }
    list
}

pub(super) fn title(hwnd: HWND) -> String {
    unsafe {
        let len = GetWindowTextLengthW(hwnd);
        if len <= 0 {
            return String::new();
        }
        let mut buf = vec![0u16; len as usize + 1];
        let n = GetWindowTextW(hwnd, &mut buf);
        String::from_utf16_lossy(&buf[..n.max(0) as usize])
    }
}

pub(super) fn exe_path(pid: u32) -> Option<String> {
    unsafe {
        let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
        let mut buf = vec![0u16; 1024];
        let mut size = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(handle, PROCESS_NAME_WIN32, PWSTR(buf.as_mut_ptr()), &mut size).is_ok();
        let _ = CloseHandle(handle);
        ok.then(|| String::from_utf16_lossy(&buf[..size as usize]))
    }
}

/// De naam uit de versie-informatie van een programma ("Google Chrome"), anders de bestandsnaam.
fn display_name(path: &str) -> Option<String> {
    unsafe {
        let wide = HSTRING::from(path);
        let size = GetFileVersionInfoSizeW(&wide, None);
        if size == 0 {
            return None;
        }
        let mut data = vec![0u8; size as usize];
        GetFileVersionInfoW(&wide, None, size, data.as_mut_ptr() as *mut _).ok()?;
        let mut pointer = std::ptr::null_mut();
        let mut len = 0u32;
        if !VerQueryValueW(data.as_ptr() as *const _, &HSTRING::from("\\VarFileInfo\\Translation"), &mut pointer, &mut len).as_bool()
            || len < 4
        {
            return None;
        }
        let words = std::slice::from_raw_parts(pointer as *const u16, 2);
        let key = format!("\\StringFileInfo\\{:04x}{:04x}\\FileDescription", words[0], words[1]);
        if !VerQueryValueW(data.as_ptr() as *const _, &HSTRING::from(key), &mut pointer, &mut len).as_bool() || len == 0 {
            return None;
        }
        let text = std::slice::from_raw_parts(pointer as *const u16, len as usize);
        let name = String::from_utf16_lossy(text).trim_end_matches('\0').trim().to_string();
        (!name.is_empty()).then_some(name)
    }
}

pub(super) fn cloaked(hwnd: HWND) -> bool {
    let mut value = 0u32;
    unsafe {
        DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &mut value as *mut u32 as *mut _, std::mem::size_of::<u32>() as u32).is_ok()
            && value != 0
    }
}

pub struct WindowsScreen {
    names: std::sync::Mutex<BTreeMap<String, String>>,
}

impl WindowsScreen {
    pub fn new() -> Self {
        Self { names: std::sync::Mutex::new(BTreeMap::new()) }
    }

    fn describe(&self, hwnd: HWND) -> Option<Win> {
        unsafe {
            if !IsWindowVisible(hwnd).as_bool() || IsIconic(hwnd).as_bool() || cloaked(hwnd) {
                return None;
            }
            if (GetWindowLongW(hwnd, GWL_EXSTYLE) as u32) & WS_EX_TOOLWINDOW.0 != 0 {
                return None;
            }
            let mut rect = RECT::default();
            GetWindowRect(hwnd, &mut rect).ok()?;
            if rect.right - rect.left <= 200 || rect.bottom - rect.top <= 100 {
                return None;
            }
            let title = title(hwnd);
            if title.is_empty() {
                return None;
            }
            let mut pid = 0u32;
            GetWindowThreadProcessId(hwnd, Some(&mut pid));
            if pid == std::process::id() {
                return None;
            }
            let path = exe_path(pid).unwrap_or_default();
            let exe = std::path::Path::new(&path).file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
            let name = {
                let mut cache = self.names.lock().unwrap_or_else(|e| e.into_inner());
                cache.entry(path.clone()).or_insert_with(|| display_name(&path).unwrap_or_else(|| exe.clone())).clone()
            };
            if screen::is_excluded(&exe) || screen::is_excluded(&name) {
                return None;
            }
            // De shell zelf (bureaublad, taakbalk) is geen venster om te lezen.
            if ["explorer", "applicationframehost", "textinputhost", "shellexperiencehost", "searchhost", "startmenuexperiencehost"]
                .contains(&exe.to_lowercase().as_str())
                && (title == "Program Manager" || exe.eq_ignore_ascii_case("textinputhost"))
            {
                return None;
            }
            Some(Win { hwnd: hwnd.0 as isize, title, exe, name, pid, rect })
        }
    }

    fn list(&self) -> Vec<Win> {
        top_windows().into_iter().filter_map(|h| self.describe(h)).collect()
    }

    fn find(&self, id: &str) -> Option<Win> {
        let raw: isize = id.strip_prefix("hwnd:")?.parse().ok()?;
        self.list().into_iter().find(|w| w.hwnd == raw)
    }

    fn front(&self) -> Option<isize> {
        let hwnd = unsafe { GetForegroundWindow() };
        (!hwnd.0.is_null()).then_some(hwnd.0 as isize)
    }

    fn read(&self, win: &Win, limit: usize) -> Option<(String, u64)> {
        let text = uia_text(HWND(win.hwnd as *mut _), limit).unwrap_or_default();
        let capture = capture_window(win);
        let print = capture.as_ref().map(|(rgba, w, h)| imaging::rgba_fingerprint(rgba, *w, *h)).unwrap_or(0);
        if text.trim().chars().count() >= 20 {
            return Some((text, print));
        }
        // Weinig of geen tekst via UI Automation: lees de pixels.
        let ocr = capture.and_then(|(rgba, w, h)| ocr(&rgba, w, h).ok()).unwrap_or_default();
        Some((if ocr.trim().len() > text.trim().len() { ocr } else { text }, print))
    }
}

/// De tekst van een venster via UI Automation: namen van knoppen, cellen en koppen, waarden van velden en de tekst
/// van documenten. Nooit wachtwoordvelden; menu's, werkbalken en schuifbalken zijn geen inhoud.
fn uia_text(hwnd: HWND, limit: usize) -> windows::core::Result<String> {
    com();
    unsafe {
        let automation: IUIAutomation = CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER)?;
        let root = automation.ElementFromHandle(hwnd)?;
        let cache = automation.CreateCacheRequest()?;
        cache.AddProperty(UIA_NamePropertyId)?;
        cache.AddProperty(UIA_ControlTypePropertyId)?;
        cache.AddProperty(UIA_IsPasswordPropertyId)?;
        let condition = automation.CreateTrueCondition()?;
        let all = root.FindAllBuildCache(TreeScope_Descendants, &condition, &cache)?;
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
        let mut documents = 0;
        for i in 0..all.Length()?.min(6000) {
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
            let mut parts: Vec<String> = Vec::new();
            if (kind == UIA_DocumentControlTypeId || kind == UIA_EditControlTypeId) && documents < 20 {
                documents += 1;
                if let Ok(pattern) = element.GetCurrentPatternAs::<IUIAutomationTextPattern>(UIA_TextPatternId) {
                    if let Ok(text) = pattern.DocumentRange().and_then(|r| r.GetText((limit - count).min(60_000) as i32)) {
                        parts.push(text.to_string());
                    }
                } else if let Ok(pattern) = element.GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId) {
                    if let Ok(value) = pattern.CurrentValue() {
                        parts.push(value.to_string());
                    }
                }
            }
            if parts.is_empty() {
                let name: BSTR = element.CachedName().unwrap_or_default();
                parts.push(name.to_string());
            }
            for part in parts {
                let clean = part.trim().to_string();
                if !clean.is_empty() && lines.last() != Some(&clean) {
                    count += clean.chars().count() + 1;
                    lines.push(clean);
                }
            }
        }
        Ok(lines.join("\n"))
    }
}

/// Pixels van een stuk scherm (in schermcoördinaten) of van een venster (`PrintWindow`, ook als het bedekt is), als RGBA.
fn grab(hwnd: Option<HWND>, x: i32, y: i32, width: i32, height: i32) -> Option<(Vec<u8>, u32, u32)> {
    if width <= 0 || height <= 0 {
        return None;
    }
    unsafe {
        let screen: HDC = GetDC(None);
        let memory = CreateCompatibleDC(Some(screen));
        let bitmap: HBITMAP = CreateCompatibleBitmap(screen, width, height);
        let old = SelectObject(memory, bitmap.into());
        let ok = match hwnd {
            // PW_RENDERFULLCONTENT (2): ook vensters die met DirectComposition tekenen.
            Some(h) => PrintWindow(h, memory, PRINT_WINDOW_FLAGS(2)).as_bool(),
            None => BitBlt(memory, 0, 0, width, height, Some(screen), x, y, SRCCOPY).is_ok(),
        };
        let mut info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: width,
                biHeight: -height,
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        let mut pixels = vec![0u8; (width * height * 4) as usize];
        let lines = GetDIBits(memory, bitmap, 0, height as u32, Some(pixels.as_mut_ptr() as *mut _), &mut info, DIB_RGB_COLORS);
        SelectObject(memory, old);
        let _ = DeleteObject(bitmap.into());
        let _ = DeleteDC(memory);
        ReleaseDC(None, screen);
        if !ok || lines == 0 {
            return None;
        }
        for px in pixels.chunks_exact_mut(4) {
            px.swap(0, 2);
            px[3] = 255;
        }
        Some((pixels, width as u32, height as u32))
    }
}

fn capture_window(win: &Win) -> Option<(Vec<u8>, u32, u32)> {
    let (w, h) = (win.rect.right - win.rect.left, win.rect.bottom - win.rect.top);
    grab(Some(HWND(win.hwnd as *mut _)), 0, 0, w, h)
}

/// Tekstherkenning van Windows zelf, in de talen van het gebruikersprofiel.
fn ocr(rgba: &[u8], width: u32, height: u32) -> windows::core::Result<String> {
    let engine = OcrEngine::TryCreateFromUserProfileLanguages()?;
    let max = OcrEngine::MaxImageDimension()?;
    if width > max || height > max {
        return Ok(String::new());
    }
    let mut bgra = rgba.to_vec();
    for px in bgra.chunks_exact_mut(4) {
        px.swap(0, 2);
    }
    let bitmap = SoftwareBitmap::CreateWithAlpha(BitmapPixelFormat::Bgra8, width as i32, height as i32, BitmapAlphaMode::Premultiplied)?;
    bitmap.CopyFromBuffer(&CryptographicBuffer::CreateFromByteArray(&bgra)?)?;
    let result = engine.RecognizeAsync(&bitmap)?.join()?;
    let lines = result.Lines()?;
    let mut out = Vec::new();
    for line in lines {
        out.push(line.Text()?.to_string());
    }
    Ok(out.join("\n"))
}

impl ScreenReader for WindowsScreen {
    fn available(&self) -> bool {
        true
    }

    fn windows(&self) -> Vec<SeenWindow> {
        let front = self.front();
        let list = self.list();
        let front = front.filter(|f| list.iter().any(|w| w.hwnd == *f)).or(list.first().map(|w| w.hwnd));
        list.into_iter()
            .map(|w| SeenWindow {
                id: format!("hwnd:{}", w.hwnd),
                app: w.name,
                title: w.title,
                display: "1".into(),
                frontmost: Some(w.hwnd) == front,
            })
            .collect()
    }

    fn read_window(&self, id: &str) -> Option<(String, u64)> {
        let win = self.find(id)?;
        self.read(&win, 8000)
    }

    fn fingerprint(&self, id: &str) -> Option<u64> {
        let win = self.find(id)?;
        capture_window(&win).map(|(rgba, w, h)| imaging::rgba_fingerprint(&rgba, w, h))
    }

    fn frontmost(&self) -> Option<WindowText> {
        let front = self.windows().into_iter().find(|w| w.frontmost)?;
        let (text, _) = self.read_window(&front.id)?;
        Some(WindowText { app: front.app, title: front.title, text, frontmost: true })
    }

    fn all_windows(&self) -> Vec<WindowText> {
        self.windows()
            .into_iter()
            .take(6)
            .filter_map(|w| {
                let (text, _) = self.read_window(&w.id)?;
                Some(WindowText { app: w.app, title: w.title, text, frontmost: w.frontmost })
            })
            .collect()
    }

    fn read_app(&self, query: &str, limit: usize) -> Result<Vec<(String, String)>, String> {
        let wanted = query.trim();
        if wanted.is_empty() {
            return Err("Welke app wil je lezen?".into());
        }
        let list = self.list();
        let mut names: Vec<String> = list.iter().flat_map(|w| [w.name.clone(), w.exe.clone()]).collect();
        names.sort();
        names.dedup();
        let Some(found) = fuzzy::best(wanted, &names) else {
            return Err(format!("{wanted} is nu niet geopend. Vraag Nook \"open {wanted}\", dan kan hij daarna meelezen."));
        };
        let mut sections = Vec::new();
        let mut remaining = limit;
        for win in list.iter().filter(|w| w.name == found || w.exe == found).take(3) {
            if remaining <= 200 {
                break;
            }
            if let Some((text, _)) = self.read(win, remaining).filter(|(t, _)| !t.trim().is_empty()) {
                remaining = remaining.saturating_sub(text.chars().count());
                sections.push((win.title.clone(), text));
            }
        }
        if sections.is_empty() {
            return Err(format!("{found} heeft op dit moment geen leesbare tekst."));
        }
        Ok(sections)
    }

    fn active_app(&self) -> Option<RunningApp> {
        let front = self.front()?;
        let win = self.list().into_iter().find(|w| w.hwnd == front)?;
        Some(RunningApp { name: win.name, id: win.exe, pid: win.pid, frontmost: true, title: win.title })
    }

    fn running_apps(&self) -> Vec<RunningApp> {
        let front = self.front();
        let mut apps: Vec<RunningApp> = Vec::new();
        for w in self.list() {
            if let Some(app) = apps.iter_mut().find(|a| a.id == w.exe) {
                app.frontmost |= Some(w.hwnd) == front;
                continue;
            }
            apps.push(RunningApp { name: w.name, id: w.exe, pid: w.pid, frontmost: Some(w.hwnd) == front, title: w.title });
        }
        apps
    }

    fn can_capture(&self) -> bool {
        true
    }

    fn capture_screen(&self) -> Result<Capture, String> {
        let (x, y, w, h) = unsafe {
            (
                GetSystemMetrics(SM_XVIRTUALSCREEN),
                GetSystemMetrics(SM_YVIRTUALSCREEN),
                GetSystemMetrics(SM_CXVIRTUALSCREEN),
                GetSystemMetrics(SM_CYVIRTUALSCREEN),
            )
        };
        let (rgba, width, height) = grab(None, x, y, w, h).ok_or("De schermafbeelding mislukte.")?;
        Ok(Capture { png: imaging::png(&rgba, width, height)?, width, height })
    }

    fn idle_seconds(&self) -> f64 {
        unsafe {
            let mut info = LASTINPUTINFO { cbSize: std::mem::size_of::<LASTINPUTINFO>() as u32, dwTime: 0 };
            if GetLastInputInfo(&mut info).as_bool() {
                GetTickCount().wrapping_sub(info.dwTime) as f64 / 1000.0
            } else {
                0.0
            }
        }
    }
}
