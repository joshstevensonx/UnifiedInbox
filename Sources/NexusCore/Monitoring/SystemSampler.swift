#if os(macOS)
import Darwin
import Foundation
import IOKit.ps

/// Reads system metrics through public macOS APIs.
/// Not thread-safe: the monitor drives it from one serial queue (never the main thread),
/// which is what makes the `@unchecked Sendable` safe.
public final class SystemSampler: @unchecked Sendable {
    private let host = mach_host_self()
    private var previousTicks: CPUTicks?
    private var previousNet: NetworkCounters?

    public init() {}

    /// Forget deltas (after sleep/wake or network changes) so the next sample isn't a spike.
    public func resetBaselines() {
        previousTicks = nil
        previousNet = nil
    }

    // MARK: CPU

    public func cpu() -> CPUReading? {
        guard let ticks = cpuTicks() else { return nil }
        defer { previousTicks = ticks }
        guard let prev = previousTicks else { return nil }
        return CPUTicks.usage(from: prev, to: ticks)
    }

    private func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks // (user, system, idle, nice)
        return CPUTicks(user: UInt64(t.0), system: UInt64(t.1), idle: UInt64(t.2), nice: UInt64(t.3))
    }

    // MARK: Memory

    public func memory() -> MemoryReading? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        // Same definition as Activity Monitor: App Memory + Wired + Compressed.
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        return MemoryReading(
            totalBytes: ProcessInfo.processInfo.physicalMemory,
            usedBytes: app + wired + compressed,
            wiredBytes: wired,
            compressedBytes: compressed,
            pressure: MemoryPressure(sysctlLevel: Self.sysctlInt32("kern.memorystatus_vm_pressure_level"))
        )
    }

    // MARK: Battery

    /// nil = couldn't query power sources; `.noBattery` = desktop Mac.
    public func battery() -> BatteryState? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
            let onAC = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let minutesKey = charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            let minutes = (desc[minutesKey] as? Int).flatMap { $0 > 0 ? $0 : nil } // -1 = still calculating
            return .reading(BatteryReading(level: Double(current) / Double(max), isCharging: charging,
                                           onACPower: onAC, minutesRemaining: minutes))
        }
        return .noBattery
    }

    // MARK: Network

    public func network() -> NetworkReading? {
        guard let counters = networkCounters() else { return nil }
        defer { previousNet = counters }
        guard let prev = previousNet else { return nil }
        return NetworkCounters.throughput(from: prev, to: counters)
    }

    private func networkCounters() -> NetworkCounters? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var bytesIn: UInt64 = 0, bytesOut: UInt64 = 0
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let data = ifa.ifa_data,
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            guard NetworkCounters.isCountedInterface(name) else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            bytesIn += UInt64(d.ifi_ibytes)
            bytesOut += UInt64(d.ifi_obytes)
        }
        return NetworkCounters(bytesIn: bytesIn, bytesOut: bytesOut, timestamp: Date())
    }

    // MARK: Storage / uptime / identity

    public func storage() -> StorageReading? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return StorageReading(totalBytes: Int64(total), availableBytes: available)
    }

    public func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    public static func identity() -> MacIdentity {
        let p = ProcessInfo.processInfo
        let v = p.operatingSystemVersion
        return MacIdentity(
            name: Host.current().localizedName ?? p.hostName,
            model: sysctlString("hw.model") ?? "Mac",
            chip: sysctlString("machdep.cpu.brand_string") ?? "Unknown processor",
            osVersion: "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : ""),
            physicalMemory: p.physicalMemory,
            cpuCount: p.activeProcessorCount
        )
    }

    // MARK: sysctl helpers

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }
}
#endif
