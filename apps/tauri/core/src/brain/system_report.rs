//! System and network status reports for Nook Chat (`system_status` and `network_status`, matching the Mac's
//! `MacReport` and `NetworkReport`). Readings are gathered on demand when the brain asks; nothing runs in the
//! background.

use std::collections::HashMap;
use std::path::Path;
use std::time::Duration;

use sysinfo::{Disks, ProcessRefreshKind, ProcessesToUpdate, System};

/// One active local IPv4 interface address.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NetworkAddress {
    pub interface: String,
    pub address: String,
}

/// Which IP addresses this device has right now ("wat is mijn IP-adres?").
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct NetworkReport {
    pub addresses: Vec<NetworkAddress>,
    pub public_address: Option<String>,
}

impl NetworkReport {
    /// Cloudflare's trace (`ip=…` on a line of its own) → the address the internet sees.
    pub fn parse_public_address(trace: &str) -> Option<String> {
        trace.lines().find_map(|line| line.trim().strip_prefix("ip=")).map(str::trim).filter(|s| !s.is_empty()).map(str::to_string)
    }

    pub fn format(&self) -> String {
        let mut lines = vec![match &self.public_address {
            Some(ip) => format!("Public IP address (what the internet sees): {ip}."),
            None => "Public IP address: could not be read, the device may be offline.".into(),
        }];
        if self.addresses.is_empty() {
            lines.push("No local network address: the device is not on a network.".into());
        } else {
            for item in &self.addresses {
                lines.push(format!("Local IP address on {}: {}.", item.interface, item.address));
            }
        }
        lines.join("\n")
    }
}

/// Asks Cloudflare's trace once (with a short timeout) for the public IP address.
pub async fn fetch_public_address() -> Option<String> {
    let client = reqwest::Client::builder().timeout(Duration::from_secs(4)).build().ok()?;
    let body = client.get("https://one.one.one.one/cdn-cgi/trace").send().await.ok()?.text().await.ok()?;
    NetworkReport::parse_public_address(&body)
}

/// CPU and memory usage for one grouped application or process.
#[derive(Debug, Clone, PartialEq)]
pub struct ProcessLoad {
    pub name: String,
    pub cpu: f64,
    pub memory_mb: f64,
}

/// How this computer is doing right now: processor, memory, temperature, battery, disk, uptime and heaviest apps.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct SystemReport {
    /// Busy share of all cores, 0…100.
    pub cpu: Option<f64>,
    pub memory_used_gb: Option<f64>,
    pub memory_total_gb: Option<f64>,
    /// 1 normal, 2 warning/high, 4 critical (when the platform reports memory pressure).
    pub memory_pressure: Option<u8>,
    /// 0 nominal … 3 critical.
    pub thermal: Option<u8>,
    pub battery_percent: Option<u8>,
    pub on_power: Option<bool>,
    pub disk_free_gb: Option<f64>,
    pub disk_total_gb: Option<f64>,
    pub uptime_hours: Option<f64>,
    pub apps: Vec<ProcessLoad>,
}

impl SystemReport {
    /// Groups helper/child entries with their app, removes `.exe` suffixes, and sorts heaviest first.
    pub fn aggregate_processes<I: IntoIterator<Item = ProcessLoad>>(entries: I) -> Vec<ProcessLoad> {
        let mut totals: HashMap<String, ProcessLoad> = HashMap::new();
        for entry in entries {
            let name = normalize_process_name(&entry.name);
            if name.is_empty() || name == "ps" {
                continue;
            }
            let item = totals.entry(name.clone()).or_insert(ProcessLoad { name, cpu: 0.0, memory_mb: 0.0 });
            item.cpu += entry.cpu;
            item.memory_mb += entry.memory_mb;
        }
        let mut list: Vec<ProcessLoad> = totals.into_values().collect();
        list.sort_by(|a, b| b.cpu.total_cmp(&a.cpu).then_with(|| b.memory_mb.total_cmp(&a.memory_mb)));
        list
    }

    /// Reads CPU (measured over 500 ms), memory, disk, uptime, and running processes synchronously via `sysinfo`.
    pub fn collect(battery: Option<(u8, bool)>, hot: bool) -> Self {
        let mut cpu = None;
        let mut memory_used_gb = None;
        let mut memory_total_gb = None;
        let mut apps = Vec::new();
        if let Ok(mut sys) = System::new() {
            let proc_kind = ProcessRefreshKind::nothing().with_cpu().with_memory();
            sys.refresh_cpu_usage();
            sys.refresh_processes_specifics(ProcessesToUpdate::All, true, proc_kind);
            std::thread::sleep(Duration::from_millis(500));
            sys.refresh_cpu_usage();
            sys.refresh_memory();
            sys.refresh_processes_specifics(ProcessesToUpdate::All, true, proc_kind);

            cpu = (!sys.cpus().is_empty()).then_some(sys.global_cpu_usage() as f64);
            let total_mem = sys.total_memory();
            if total_mem > 0 {
                let total = total_mem as f64 / 1_073_741_824.0;
                let avail = sys.available_memory() as f64 / 1_073_741_824.0;
                let used = if avail > 0.0 { (total - avail).max(0.0) } else { sys.used_memory() as f64 / 1_073_741_824.0 };
                memory_used_gb = Some(used);
                memory_total_gb = Some(total);
            }
            apps = Self::aggregate_processes(sys.processes().values().map(|p| ProcessLoad {
                name: p.name().to_string_lossy().into_owned(),
                cpu: p.cpu_usage() as f64,
                memory_mb: p.memory() as f64 / 1_048_576.0,
            }));
        }

        let home = dirs::home_dir();
        let (disk_free_gb, disk_total_gb) =
            Disks::new_with_refreshed_list().ok().map(|d| pick_disk(&d, home.as_deref())).unwrap_or((None, None));

        let uptime_hours = System::uptime().ok().filter(|&up| up > 0).map(|up| up as f64 / 3600.0);

        Self {
            cpu,
            memory_used_gb,
            memory_total_gb,
            memory_pressure: None,
            thermal: hot.then_some(2),
            battery_percent: battery.map(|(p, _)| p),
            on_power: battery.map(|(_, on)| on),
            disk_free_gb,
            disk_total_gb,
            uptime_hours,
            apps,
        }
    }

    /// The report for the brain, with what stands out first.
    pub fn format(&self) -> String {
        let mut lines = Vec::new();
        let mut notable = Vec::new();
        if let Some(cpu) = self.cpu {
            lines.push(format!("Processor: {:.0}% busy (all cores together).", cpu.round()));
            if cpu >= 70.0 {
                notable.push("the processor is very busy");
            }
        }
        if let (Some(used), Some(total)) = (self.memory_used_gb, self.memory_total_gb) {
            let mut line = format!("Memory: {used:.1} of {total:.0} GB in use");
            if let Some(pressure) = self.memory_pressure {
                let label = if pressure >= 4 {
                    "critical"
                } else if pressure >= 2 {
                    "high (swapping)"
                } else {
                    "normal"
                };
                line.push_str(", pressure ");
                line.push_str(label);
                if pressure >= 2 {
                    notable.push("memory is short");
                }
            } else if total > 0.0 && used / total >= 0.90 {
                notable.push("memory is short");
            }
            line.push('.');
            lines.push(line);
        }
        if let Some(thermal) = self.thermal {
            let words = ["normal", "warm", "hot (slowed down to cool)", "critical (strongly slowed down)"];
            let word = words[thermal.min(3) as usize];
            lines.push(format!("Temperature: {word}."));
            if thermal >= 2 {
                notable.push("the computer is hot and slowed down");
            }
        }
        if let Some(percent) = self.battery_percent {
            let power = if self.on_power == Some(true) { ", charging or on power." } else { ", on battery." };
            lines.push(format!("Battery: {percent}%{power}"));
            if percent <= 15 && self.on_power != Some(true) {
                notable.push("the battery is almost empty");
            }
        }
        if let (Some(free), Some(total)) = (self.disk_free_gb, self.disk_total_gb) {
            lines.push(format!("Disk: {free:.0} GB free of {total:.0} GB."));
            if free < 15.0 || free / total.max(1.0) < 0.08 {
                notable.push("the disk is nearly full");
            }
        }
        if let Some(uptime) = self.uptime_hours {
            if uptime >= 48.0 {
                lines.push(format!("Up for {} days without a restart.", (uptime / 24.0) as u64));
            } else {
                lines.push(format!("Up for {} hours.", uptime as u64));
            }
            if uptime >= 24.0 * 14.0 {
                notable.push("the computer has not restarted in over two weeks");
            }
        }
        let heavy: Vec<String> = self
            .apps
            .iter()
            .take(6)
            .map(|app| {
                if app.memory_mb >= 1024.0 {
                    format!("{} {:.0}% CPU, {:.1} GB", app.name, app.cpu, app.memory_mb / 1024.0)
                } else {
                    format!("{} {:.0}% CPU, {:.0} MB", app.name, app.cpu, app.memory_mb)
                }
            })
            .collect();
        if !heavy.is_empty() {
            lines.push(format!("Heaviest apps now: {}.", heavy.join("; ")));
        }
        let summary = if notable.is_empty() {
            "Nothing unusual: the computer is not under strain right now.".to_string()
        } else {
            format!("Stands out: {}.", notable.join(", "))
        };
        if lines.is_empty() {
            format!("This computer right now. {summary}")
        } else {
            format!("This computer right now. {summary}\n{}", lines.join("\n"))
        }
    }
}

fn normalize_process_name(raw: &str) -> String {
    let mut name = raw.trim();
    if let Some(stripped) = name.strip_suffix(".exe").or_else(|| name.strip_suffix(".EXE")) {
        name = stripped;
    }
    if let Some(idx) = name.find(" Helper") {
        name = &name[..idx];
    }
    if name.ends_with(" Web Content") || name == "com.apple.WebKit.WebContent" {
        return "Safari (webpagina's)".into();
    }
    name.trim().to_string()
}

fn pick_disk(disks: &Disks, target: Option<&Path>) -> (Option<f64>, Option<f64>) {
    let best = target
        .and_then(|path| {
            disks
                .iter()
                .filter(|d| d.total_space() > 0 && path.starts_with(d.mount_point()))
                .max_by_key(|d| d.mount_point().as_os_str().len())
        })
        .or_else(|| disks.iter().find(|d| d.total_space() > 0));
    match best {
        Some(d) => (Some(d.available_space() as f64 / 1_000_000_000.0), Some(d.total_space() as f64 / 1_000_000_000.0)),
        None => (None, None),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn processes_add_up_per_app() {
        let apps = SystemReport::aggregate_processes([
            ProcessLoad { name: "Google Chrome Helper (Renderer)".into(), cpu: 85.2, memory_mb: 500.0 },
            ProcessLoad { name: "Google Chrome".into(), cpu: 20.0, memory_mb: 250.0 },
            ProcessLoad { name: "explorer.exe".into(), cpu: 3.1, memory_mb: 100.0 },
            ProcessLoad { name: "ps".into(), cpu: 0.0, memory_mb: 2.0 },
        ]);
        assert_eq!(apps[0].name, "Google Chrome");
        assert!((apps[0].cpu - 105.2).abs() < 0.01);
        assert!((apps[0].memory_mb - 750.0).abs() < 0.1);
        assert_eq!(apps.iter().map(|a| a.name.as_str()).collect::<Vec<_>>(), vec!["Google Chrome", "explorer"]);
    }

    #[test]
    fn what_stands_out() {
        let report = SystemReport {
            cpu: Some(92.0),
            memory_used_gb: Some(15.1),
            memory_total_gb: Some(16.0),
            memory_pressure: Some(2),
            thermal: Some(2),
            battery_percent: Some(9),
            on_power: Some(false),
            disk_free_gb: Some(8.0),
            disk_total_gb: Some(500.0),
            uptime_hours: Some(400.0),
            apps: vec![ProcessLoad { name: "Code".into(), cpu: 80.0, memory_mb: 4_096.0 }],
        };
        let text = report.format();
        assert!(
            text.contains(
                "the processor is very busy, memory is short, the computer is hot and slowed down, the battery is almost empty, the disk is nearly full"
            ),
            "{text}"
        );
        assert!(text.contains("Code 80% CPU, 4.0 GB"), "{text}");

        let quiet = SystemReport { cpu: Some(12.0), memory_pressure: Some(1), thermal: Some(0), ..Default::default() };
        assert!(quiet.format().contains("Nothing unusual"));
    }

    #[test]
    fn high_memory_fraction_flags_shortage_without_pressure() {
        let report = SystemReport { memory_used_gb: Some(15.0), memory_total_gb: Some(16.0), ..Default::default() };
        assert!(report.format().contains("memory is short"));
    }

    #[test]
    fn network_report_formats_and_parses_trace() {
        assert_eq!(NetworkReport::parse_public_address("fl=1\nip=203.0.113.7\nts=1").as_deref(), Some("203.0.113.7"));
        assert_eq!(NetworkReport::parse_public_address("ip="), None);
        let text = NetworkReport {
            addresses: vec![NetworkAddress { interface: "eth0".into(), address: "192.168.1.20".into() }],
            public_address: Some("203.0.113.7".into()),
        }
        .format();
        assert!(text.contains("203.0.113.7"), "{text}");
        assert!(text.contains("eth0: 192.168.1.20"), "{text}");
        assert!(NetworkReport::default().format().contains("could not be read"));
    }
}
