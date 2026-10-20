//! Meetings, screen sharing and power on Windows: the top-level windows on screen (a sharing bar of Zoom, Teams or a
//! browser), which programs have the microphone open (the privacy registry Windows keeps for its microphone icon), the
//! battery and battery saver (`GetSystemPowerStatus`) and how busy the processor is (`GetSystemTimes`).

use std::sync::Mutex;

use nook_core::platform::{PowerMonitor, QuietWatch};
use nook_core::services::energy::EnergySignals;
use nook_core::services::quiet::Window;
use windows::core::{HSTRING, PWSTR};
use windows::Win32::Foundation::{ERROR_SUCCESS, FILETIME, HWND, RECT};
use windows::Win32::System::Power::{GetSystemPowerStatus, SYSTEM_POWER_STATUS};
use windows::Win32::System::Registry::{
    RegCloseKey, RegEnumKeyExW, RegGetValueW, RegOpenKeyExW, HKEY, HKEY_CURRENT_USER, KEY_READ, RRF_RT_REG_QWORD,
};
use windows::Win32::System::Threading::GetSystemTimes;
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::WindowsAndMessaging::{GetWindowRect, GetWindowThreadProcessId, IsIconic, IsWindowVisible};

use super::screen::{cloaked, exe_path, title, top_windows};

/// Where Windows notes which program last used the microphone and whether it still does.
const MICROPHONE: &str = r"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";

pub struct WindowsQuiet;

impl QuietWatch for WindowsQuiet {
    fn available(&self) -> bool {
        true
    }

    fn windows(&self) -> Vec<Window> {
        let own = std::process::id();
        top_windows()
            .into_iter()
            .filter_map(|hwnd| unsafe {
                if !IsWindowVisible(hwnd).as_bool() || IsIconic(hwnd).as_bool() || cloaked(hwnd) {
                    return None;
                }
                let mut pid = 0u32;
                GetWindowThreadProcessId(hwnd, Some(&mut pid));
                if pid == own {
                    return None;
                }
                let mut rect = RECT::default();
                GetWindowRect(hwnd, &mut rect).ok()?;
                let path = exe_path(pid).unwrap_or_default();
                let exe = std::path::Path::new(&path).file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
                Some(Window { owner: exe, name: title(hwnd), height: logical_height(hwnd, &rect) })
            })
            .collect()
    }

    fn microphone_apps(&self) -> Vec<String> {
        let mut apps = in_use(MICROPHONE, false);
        apps.extend(in_use(&format!(r"{MICROPHONE}\NonPackaged"), true));
        let own = std::env::current_exe().ok().and_then(|p| p.file_stem().map(|s| s.to_string_lossy().to_lowercase())).unwrap_or_default();
        apps.retain(|a| !a.is_empty() && !a.to_lowercase().contains(&own));
        apps
    }
}

/// The window's height in logical pixels: a sharing bar is small at any display scale.
fn logical_height(hwnd: HWND, rect: &RECT) -> f64 {
    let dpi = unsafe { GetDpiForWindow(hwnd) };
    let scale = if dpi == 0 { 1.0 } else { dpi as f64 / 96.0 };
    (rect.bottom - rect.top) as f64 / scale
}

/// The programs under `path` that use the microphone right now: started (`LastUsedTimeStart`) and not stopped
/// (`LastUsedTimeStop` is 0). `paths`: the key names are program paths with `#` for `\` (desktop programs); otherwise
/// they are Store package names.
fn in_use(path: &str, paths: bool) -> Vec<String> {
    let mut found = vec![];
    unsafe {
        let mut key = HKEY::default();
        if RegOpenKeyExW(HKEY_CURRENT_USER, &HSTRING::from(path), None, KEY_READ, &mut key) != ERROR_SUCCESS {
            return found;
        }
        let mut index = 0u32;
        loop {
            let mut buf = vec![0u16; 512];
            let mut len = buf.len() as u32;
            if RegEnumKeyExW(key, index, Some(PWSTR(buf.as_mut_ptr())), &mut len, None, None, None, None) != ERROR_SUCCESS {
                break;
            }
            index += 1;
            let name = String::from_utf16_lossy(&buf[..len as usize]);
            let start = qword(key, &name, "LastUsedTimeStart").unwrap_or(0);
            let stop = qword(key, &name, "LastUsedTimeStop").unwrap_or(1);
            if start == 0 || stop != 0 {
                continue;
            }
            found.push(if paths {
                let file = name.rsplit('#').next().unwrap_or(&name);
                file.strip_suffix(".exe").or_else(|| file.strip_suffix(".EXE")).unwrap_or(file).to_string()
            } else {
                name
            });
        }
        let _ = RegCloseKey(key);
    }
    found
}

unsafe fn qword(key: HKEY, subkey: &str, value: &str) -> Option<u64> {
    let mut data = 0u64;
    let mut size = std::mem::size_of::<u64>() as u32;
    let status = RegGetValueW(
        key,
        &HSTRING::from(subkey),
        &HSTRING::from(value),
        RRF_RT_REG_QWORD,
        None,
        Some(&mut data as *mut u64 as *mut _),
        Some(&mut size),
    );
    (status == ERROR_SUCCESS).then_some(data)
}

fn ticks(time: FILETIME) -> u64 {
    (time.dwHighDateTime as u64) << 32 | time.dwLowDateTime as u64
}

/// Battery, battery saver and processor load. The load is measured between two readings (the energy plan reads every
/// ten seconds), so the first reading never counts as busy.
#[derive(Default)]
pub struct WindowsPower {
    last: Mutex<Option<(u64, u64)>>,
}

impl WindowsPower {
    pub fn new() -> Self {
        Self::default()
    }

    /// Share of the time all cores were working since the last reading, 0–1.
    fn load(&self) -> Option<f64> {
        let (mut idle, mut kernel, mut user) = (FILETIME::default(), FILETIME::default(), FILETIME::default());
        unsafe { GetSystemTimes(Some(&mut idle), Some(&mut kernel), Some(&mut user)).ok()? };
        // Kernel time includes idle time.
        let (idle, total) = (ticks(idle), ticks(kernel) + ticks(user));
        let previous = self.last.lock().unwrap_or_else(|e| e.into_inner()).replace((idle, total))?;
        let busy_total = total.saturating_sub(previous.1);
        if busy_total == 0 {
            return None;
        }
        Some(1.0 - idle.saturating_sub(previous.0) as f64 / busy_total as f64)
    }
}

impl PowerMonitor for WindowsPower {
    fn signals(&self) -> EnergySignals {
        let mut status = SYSTEM_POWER_STATUS::default();
        let power = unsafe { GetSystemPowerStatus(&mut status) }.is_ok();
        // ACLineStatus 0 = on battery; BatteryFlag 128 = no battery at all (a desktop).
        let on_battery = power && status.ACLineStatus == 0 && status.BatteryFlag != 128;
        let low_power_mode = power && status.SystemStatusFlag == 1;
        // Above 90 % on every core is the Windows counterpart of a load average above one per core.
        let busy = self.load().is_some_and(|l| l > 0.9);
        EnergySignals { low_power_mode, on_battery, busy, ..Default::default() }
    }
}
