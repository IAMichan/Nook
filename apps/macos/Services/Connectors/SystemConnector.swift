import SwiftUI
import IOKit.ps

/// "Deze Mac" as a source for the chat: processor, memory, temperature, battery, disk and the heaviest apps, read on
/// the Mac when asked (nothing runs in the background).
@MainActor
final class SystemConnector: ContextSource {
    let id = "system"
    let title = "Deze Mac"
    let symbol = "laptopcomputer"
    let accent = Color(hex: 0x8E8E93)
    private(set) var status = ConnectorStatus()
    var iconDomain: String? { nil }
    var isActive: Bool { ConnectorToggle.isOn(id) }
    var refreshInterval: TimeInterval { 3_600 }

    func refresh() async {
        status = ConnectorStatus(state: .ok, headline: tr("system.connector.headline"), detail: tr("system.connector.detail"), updated: Date())
    }

    func contextLines() -> [String] { [] }

    var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "mac_status",
                description: "How this Mac is doing right now: processor load, memory and memory pressure, temperature (slowed down or not), battery, free disk space, time since restart, and the apps using the most processor and memory. Use for \"why is my Mac slow\", \"what drains my battery\", \"how full is my disk\".",
                schema: ["type": "object", "properties": [:]],
                kind: .read,
                summarize: { _ in "Status van deze Mac" },
                tag: { _ in ("", .neutral) },
                run: { _ in await MacStatus.report().text }
            )
        ]
    }
}

/// The readings themselves.
enum MacStatus {
    static func report() async -> MacReport {
        await Task.detached(priority: .userInitiated) { () -> MacReport in
            var report = MacReport()
            if let first = cpuTicks() {
                try? await Task.sleep(for: .milliseconds(500))
                if let second = cpuTicks(), second.total > first.total {
                    report.cpu = Double(second.busy - first.busy) / Double(second.total - first.total) * 100
                }
            }
            let total = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
            report.memoryTotalGB = total
            if let free = freeMemoryGB() { report.memoryUsedGB = max(0, total - free) }
            report.memoryPressure = sysctlInt("kern.memorystatus_vm_pressure_level")
            report.thermal = ProcessInfo.processInfo.thermalState.rawValue
            if let battery = battery() {
                report.batteryPercent = battery.percent
                report.onPower = battery.onPower
            }
            let home = URL(fileURLWithPath: NSHomeDirectory())
            if let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
                if let free = values.volumeAvailableCapacityForImportantUsage { report.diskFreeGB = Double(free) / 1_000_000_000 }
                if let all = values.volumeTotalCapacity { report.diskTotalGB = Double(all) / 1_000_000_000 }
            }
            report.uptimeHours = ProcessInfo.processInfo.systemUptime / 3_600
            if let output = try? SystemControl.runProcess("/bin/ps", ["-Aceo", "pcpu=,rss=,comm=", "-r"], timeout: 5) {
                report.apps = MacReport.parseProcesses(output)
            }
            return report
        }.value
    }

    private static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return (user + system + nice, user + system + idle + nice)
    }

    /// Free and reclaimable memory (free, inactive and purgeable pages).
    private static func freeMemoryGB() -> Double? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pages = UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.purgeable_count)
        return Double(pages) * Double(vm_kernel_page_size) / 1_073_741_824
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private static func battery() -> (percent: Int, onPower: Bool)? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() else { return nil }
        for source in list as Array {
            guard let description = IOPSGetPowerSourceDescription(blob, source as CFTypeRef)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            let onPower = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return (Int((Double(current) / Double(maximum) * 100).rounded()), onPower)
        }
        return nil
    }
}
