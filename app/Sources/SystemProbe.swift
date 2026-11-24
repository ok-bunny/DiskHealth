import Darwin
import Foundation

struct CPUTicks {
    let user: UInt32
    let system: UInt32
    let idle: UInt32
    let nice: UInt32

    func usage(since previous: CPUTicks) -> Double? {
        // Mach 的各状态计数是 32 位，长时间运行后可能分别回绕。
        let busy = UInt64(user &- previous.user) + UInt64(system &- previous.system)
            + UInt64(nice &- previous.nice)
        let total = busy + UInt64(idle &- previous.idle)
        guard total > 0 else { return nil }
        return Double(busy) / Double(total)
    }
}

struct MemoryUsage {
    let usedBytes: Int64
    let totalBytes: Int64
    var fraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
}

enum SystemProbe {
    static func cpuTicks() -> CPUTicks? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }

        var info = host_cpu_load_info_data_t()
        let capacity = MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.stride
        var count = mach_msg_type_number_t(capacity)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS, count == capacity else { return nil }
        let (user, system, idle, nice) = info.cpu_ticks
        return CPUTicks(user: user, system: system, idle: idle, nice: nice)
    }

    static func memory() -> MemoryUsage? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }

        var info = vm_statistics64_data_t()
        let capacity = MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.stride
        var count = mach_msg_type_number_t(capacity)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS,
              let total = Int64(exactly: ProcessInfo.processInfo.physicalMemory), total > 0 else { return nil }

        // 以不可清除的匿名页、固定页和压缩器实际占用的物理页估算已用内存。
        let anonymous = max(0, Int64(info.internal_page_count) - Int64(info.purgeable_count))
        let usedPages = anonymous + Int64(info.wire_count) + Int64(info.compressor_page_count)
        let used = usedPages * Int64(vm_kernel_page_size)
        return MemoryUsage(usedBytes: min(used, total), totalBytes: total)
    }

    static func swap() -> MemoryUsage? {
        var info = xsw_usage()
        var size = MemoryLayout.size(ofValue: info)
        let result = sysctlbyname("vm.swapusage", &info, &size, nil, 0)
        guard result == 0, size == MemoryLayout.size(ofValue: info),
              let used = Int64(exactly: info.xsu_used),
              let total = Int64(exactly: info.xsu_total), used <= total else { return nil }
        return MemoryUsage(usedBytes: used, totalBytes: total)
    }
}
