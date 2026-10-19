import Foundation

/// How the Mac is doing, in words the brain can use: "waarom is mijn Mac traag?", "hoe vol is mijn schijf?", "wat slurpt
/// mijn batterij?". The numbers come from MacStatus (on the Mac); this part reads `ps` and writes the text (tested in
/// MacReportTests). Nook answers questions with the readings.
struct MacReport: Equatable {
    struct App: Equatable {
        var name: String
        var cpu: Double
        var memoryMB: Double
    }

    /// Busy share of all cores, 0…100.
    var cpu: Double?
    var memoryUsedGB: Double?
    var memoryTotalGB: Double?
    /// 1 normal, 2 warning, 4 critical (kern.memorystatus_vm_pressure_level).
    var memoryPressure: Int?
    /// 0 nominal … 3 critical (ProcessInfo.ThermalState).
    var thermal: Int?
    var batteryPercent: Int?
    var onPower: Bool?
    var diskFreeGB: Double?
    var diskTotalGB: Double?
    var uptimeHours: Double?
    var apps: [App] = []

    /// `ps -Aceo pcpu=,rss=,comm=` → apps, helpers counted with their app ("Google Chrome Helper (Renderer)" → Google
    /// Chrome), heaviest first.
    static func parseProcesses(_ output: String) -> [App] {
        var totals: [String: App] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let cpu = Double(parts[0].replacingOccurrences(of: ",", with: ".")), let rss = Double(parts[1]) else { continue }
            var name = String(parts[2]).trimmingCharacters(in: .whitespaces)
            if let helper = name.range(of: " Helper") { name = String(name[..<helper.lowerBound]) }
            if name.hasSuffix(" Web Content") || name == "com.apple.WebKit.WebContent" { name = "Safari (webpagina's)" }
            guard !name.isEmpty, name != "ps" else { continue }
            var app = totals[name] ?? App(name: name, cpu: 0, memoryMB: 0)
            app.cpu += cpu
            app.memoryMB += rss / 1024
            totals[name] = app
        }
        return totals.values.sorted { $0.cpu != $1.cpu ? $0.cpu > $1.cpu : $0.memoryMB > $1.memoryMB }
    }

    /// The report for the brain, with what stands out first.
    var text: String {
        var lines: [String] = []
        var notable: [String] = []
        if let cpu {
            lines.append("Processor: \(Int(cpu.rounded()))% busy (all cores together).")
            if cpu >= 70 { notable.append("the processor is very busy") }
        }
        if let used = memoryUsedGB, let total = memoryTotalGB {
            var line = String(format: "Memory: %.1f of %.0f GB in use", used, total)
            if let pressure = memoryPressure {
                line += ", pressure " + (pressure >= 4 ? "critical" : pressure >= 2 ? "high (the Mac is swapping)" : "normal")
                if pressure >= 2 { notable.append("memory is short") }
            }
            lines.append(line + ".")
        }
        if let thermal {
            let words = ["normal", "warm", "hot (slowed down to cool)", "critical (strongly slowed down)"]
            lines.append("Temperature: \(words[min(max(thermal, 0), 3)]).")
            if thermal >= 2 { notable.append("the Mac is hot and slowed down") }
        }
        if let percent = batteryPercent {
            lines.append("Battery: \(percent)%" + (onPower == true ? ", charging or on power." : ", on battery."))
            if percent <= 15, onPower != true { notable.append("the battery is almost empty") }
        }
        if let free = diskFreeGB, let total = diskTotalGB {
            lines.append(String(format: "Disk: %.0f GB free of %.0f GB.", free, total))
            if free < 15 || free / max(total, 1) < 0.08 { notable.append("the disk is nearly full") }
        }
        if let uptime = uptimeHours {
            lines.append(uptime >= 48 ? "Up for \(Int(uptime / 24)) days without a restart." : "Up for \(Int(uptime)) hours.")
            if uptime >= 24 * 14 { notable.append("the Mac has not restarted in over two weeks") }
        }
        let heavy = apps.prefix(6).map { app in
            app.memoryMB >= 1024 ? String(format: "%@ %.0f%% CPU, %.1f GB", app.name, app.cpu, app.memoryMB / 1024)
                : String(format: "%@ %.0f%% CPU, %.0f MB", app.name, app.cpu, app.memoryMB)
        }
        if !heavy.isEmpty { lines.append("Heaviest apps now: " + heavy.joined(separator: "; ") + ".") }
        let summary = notable.isEmpty ? "Nothing unusual: the Mac is not under strain right now." : "Stands out: " + notable.joined(separator: ", ") + "."
        return "This Mac right now. " + summary + "\n" + lines.joined(separator: "\n")
    }
}
