import Foundation
import Darwin

/// Memory sampling based on Stats (MIT): host_statistics64 + vm pressure sysctl.
struct MemorySnapshot: Equatable {
    var totalBytes: UInt64
    var usedBytes: UInt64
    var appBytes: UInt64
    var wiredBytes: UInt64
    var compressedBytes: UInt64
    var swapUsedBytes: UInt64
    var pressure: Pressure

    enum Pressure: Int, Equatable {
        case normal = 0
        case warn = 1
        case urgent = 2
        case critical = 4

        var title: String {
            switch self {
            case .normal: return "正常"
            case .warn: return "警告"
            case .urgent: return "紧急"
            case .critical: return "严重"
            }
        }
    }

    var usedPercent: Double {
        guard totalBytes > 0 else { return 0 }
        return min(100, Double(usedBytes) / Double(totalBytes) * 100)
    }

    var menuTitle: String {
        String(format: "MEM %.0f%%", usedPercent)
    }

    static let zero = MemorySnapshot(
        totalBytes: 1, usedBytes: 0, appBytes: 0, wiredBytes: 0,
        compressedBytes: 0, swapUsedBytes: 0, pressure: .normal
    )
}

enum MemorySampler {
    static func sample() -> MemorySnapshot {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = UInt64(pageSize)

        var app: UInt64 = 0
        var wired: UInt64 = 0
        var compressed: UInt64 = 0
        if kr == KERN_SUCCESS {
            let internalPages = UInt64(stats.internal_page_count)
            let purgeable = UInt64(stats.purgeable_count)
            app = internalPages > purgeable ? (internalPages - purgeable) * page : 0
            wired = UInt64(stats.wire_count) * page
            compressed = UInt64(stats.compressor_page_count) * page
        }
        let used = min(total, app + wired + compressed)

        var xsw = xsw_usage()
        var xswSize = MemoryLayout<xsw_usage>.size
        _ = withUnsafeMutablePointer(to: &xsw) { ptr in
            sysctlbyname("vm.swapusage", ptr, &xswSize, nil, 0)
        }

        var pressureRaw: Int32 = 0
        var pressureSize = MemoryLayout<Int32>.size
        _ = withUnsafeMutablePointer(to: &pressureRaw) { ptr in
            sysctlbyname("kern.memorystatus_vm_pressure_level", ptr, &pressureSize, nil, 0)
        }

        return MemorySnapshot(
            totalBytes: total,
            usedBytes: used,
            appBytes: app,
            wiredBytes: wired,
            compressedBytes: compressed,
            swapUsedBytes: UInt64(xsw.xsu_used),
            pressure: MemorySnapshot.Pressure(rawValue: Int(pressureRaw)) ?? .normal
        )
    }
}
