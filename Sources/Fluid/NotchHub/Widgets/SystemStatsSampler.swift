import Combine
import Darwin
import Foundation
import IOKit.ps

/// Live CPU, memory, swap, disk, battery and top-memory-apps readings. It only runs while the notch is
/// open, so it costs nothing at rest.
@MainActor
final class SystemStatsSampler: ObservableObject {
    enum MemoryPressure { case normal, warning, critical }

    struct AppUse: Identifiable, Equatable {
        let name: String
        let bytes: UInt64
        var id: String { self.name }
    }

    struct Battery: Equatable {
        let percent: Int
        let isCharging: Bool
        let isOnAC: Bool
    }

    struct Snapshot: Equatable {
        var cpu: Double = 0
        var memoryUsed: UInt64 = 0
        var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
        var pressure: MemoryPressure = .normal
        var swapUsed: UInt64 = 0
        var swapTotal: UInt64 = 0
        var diskFree: UInt64 = 0
        var diskTotal: UInt64 = 0
        var battery: Battery?
        var topApps: [AppUse] = []
    }

    @Published private(set) var snapshot = Snapshot()

    private var timer: Timer?
    private var lastCPU: (busy: UInt64, total: UInt64)?
    private var tick = 0

    func start() {
        guard self.timer == nil else { return }
        self.tick = 0
        self.sample()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        self.timer?.invalidate()
        self.timer = nil
        self.lastCPU = nil
    }

    private func sample() {
        var next = self.snapshot
        next.cpu = self.readCPU() ?? next.cpu
        let memory = Self.readMemory()
        next.memoryUsed = memory.used
        next.memoryTotal = memory.total
        next.pressure = Self.readPressure()
        let swap = Self.readSwap()
        next.swapUsed = swap.used
        next.swapTotal = swap.total
        // The slower readings refresh every few seconds.
        if self.tick % 3 == 0 {
            let disk = Self.readDisk()
            next.diskFree = disk.free
            next.diskTotal = disk.total
            next.battery = Self.readBattery()
            next.topApps = Self.readTopApps(limit: 4)
        }
        self.tick += 1
        if next != self.snapshot { self.snapshot = next }
    }

    // MARK: - CPU

    private func readCPU() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle
        defer { self.lastCPU = (busy, total) }
        guard let last = self.lastCPU, total > last.total else { return nil }
        return Double(busy - last.busy) / Double(total - last.total)
    }

    // MARK: - Memory

    private static func readMemory() -> (used: UInt64, total: UInt64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let total = ProcessInfo.processInfo.physicalMemory
        guard result == KERN_SUCCESS else { return (0, total) }
        // Activity Monitor's "Memory Used": app memory + wired + compressed.
        let page = UInt64(vm_kernel_page_size)
        let appPages = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)
        let used = (appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return (min(used, total), total)
    }

    private static func readPressure() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        switch level {
        case 4: return .critical
        case 2: return .warning
        default: return .normal
        }
    }

    private static func readSwap() -> (used: UInt64, total: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (usage.xsu_used, usage.xsu_total)
    }

    // MARK: - Disk

    private static func readDisk() -> (free: UInt64, total: UInt64) {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) else { return (0, 0) }
        return (UInt64(max(values.volumeAvailableCapacityForImportantUsage ?? 0, 0)), UInt64(max(values.volumeTotalCapacity ?? 0, 0)))
    }

    // MARK: - Battery

    private static func readBattery() -> Battery? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  let percent = description[kIOPSCurrentCapacityKey] as? Int else { continue }
            let charging = (description[kIOPSIsChargingKey] as? Bool) ?? false
            let onAC = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return Battery(percent: percent, isCharging: charging, isOnAC: onAC)
        }
        return nil
    }

    // MARK: - Top apps by memory

    private static func readTopApps(limit: Int) -> [AppUse] {
        let capacity = Int(proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)) / MemoryLayout<pid_t>.size + 32
        var pids = [pid_t](repeating: 0, count: capacity)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(capacity * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        let count = Int(bytes) / MemoryLayout<pid_t>.size

        var totals: [String: UInt64] = [:]
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(count) where pid > 0 {
            var usage = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard status == 0, usage.ri_phys_footprint > 0 else { continue }
            guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 else { continue }
            totals[Self.displayName(forPath: String(cString: pathBuffer)), default: 0] += usage.ri_phys_footprint
        }
        return totals.sorted { $0.value > $1.value }.prefix(limit).map { AppUse(name: $0.key, bytes: $0.value) }
    }

    /// Groups helper processes under their app ("Dia" instead of five "Browser Helper" lines).
    private static func displayName(forPath path: String) -> String {
        let parts = path.split(separator: "/")
        if let app = parts.first(where: { $0.hasSuffix(".app") }) {
            return String(app.dropLast(4))
        }
        var name = parts.last.map(String.init) ?? path
        if name.hasPrefix("com.apple.") { name = String(name.dropFirst("com.apple.".count)) }
        return name
    }
}
