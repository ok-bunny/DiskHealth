import Foundation

// MARK: - 健康等级

enum HealthLevel: Int, Comparable {
    case ok = 0
    case unknown = 1
    case warning = 2
    case critical = 3

    static func < (lhs: HealthLevel, rhs: HealthLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .ok: return "健康"
        case .warning: return "警告"
        case .critical: return "危险"
        case .unknown: return "未知"
        }
    }
}

struct DiskHealthSummaryLine: Identifiable {
    let level: HealthLevel
    let title: String
    let details: String
    var id: HealthLevel { level }

    static func lines(for disks: [DiskEntry], isRefreshing: Bool) -> [Self] {
        if disks.isEmpty {
            let title = isRefreshing ? "正在检测磁盘…" : "未发现物理磁盘"
            return [Self(level: .unknown, title: title, details: title)]
        }
        let groups = Dictionary(grouping: disks, by: \.health)
        if groups[.ok]?.count == disks.count {
            let title = disks.count == 1 ? "磁盘健康" : "\(disks.count) 块磁盘均健康"
            return [Self(level: .ok, title: title, details: title)]
        }
        return [HealthLevel.critical, .warning, .unknown].compactMap { level in
            guard let affected = groups[level] else { return nil }
            let names = affected.map { disk in
                if !disk.bsd.isEmpty { return disk.bsd }
                return disk.model.isEmpty ? "未命名磁盘" : disk.model
            }
            let title = "\(names.joined(separator: "、")) 磁盘健康\(level.label)"
            let details = zip(names, affected).map { name, disk in
                disk.model.isEmpty || name == disk.model ? name : "\(name) · \(disk.model)"
            }.joined(separator: "\n")
            return Self(level: level, title: title, details: details)
        }
    }
}

// MARK: - 磁盘条目（包装 C 结构体）

extension dh_ata_value_t {
    var value: UInt64? { present != 0 ? raw : nil }
}

struct DiskEntry: Identifiable {
    let info: dh_disk_info_t
    var id: String { "\(bsd)#\(serial)#\(model)" }

    var bsd: String { fixedStr(info.bsd) }
    var model: String { fixedStr(info.model) }
    var serial: String { fixedStr(info.serial) }
    var firmware: String { fixedStr(info.firmware) }
    var transport: String { fixedStr(info.transport) }

    /// 无任何 SMART 明细且无 SMART 结论
    var smartDetailUnavailable: Bool {
        !hasAnyDetail && info.smart_status == Int32(DH_SMART_UNKNOWN)
    }

    var displayName: String {
        let m = model
        return m.isEmpty ? bsd : m
    }

    var tempC: Int? {
        guard info.temperature_k > 0, info.temperature_k != 0xffff else { return nil }
        return Int(info.temperature_k) - 273
    }
    var hasNVMeDetail: Bool { info.have_nvme_detail == 1 }
    var hasATADetail: Bool { info.have_ata_detail == 1 }
    var hasAnyDetail: Bool { hasNVMeDetail || hasATADetail }

    var health: HealthLevel {
        if let reported = reasons.map(\.level).max() { return reported }
        if hasNVMeDetail { return .ok }
        // 没有设备结论时，三个关键扇区计数齐全才能据此判为健康。
        if hasATADetail, info.ata_realloc_sectors.value != nil,
           info.ata_pending_sectors.value != nil, info.ata_offline_unc.value != nil { return .ok }
        return .unknown
    }
    var healthReasons: [String] { reasons.map(\.text) }

    // MARK: 健康判定（NVMe SMART/Health 标准语义；ATA 按关键属性计数）
    private struct Reason { let level: HealthLevel; let text: String }

    private var reasons: [Reason] {
        var out: [Reason] = []
        if !hasAnyDetail {
            switch info.smart_status {
            case Int32(DH_SMART_FAILING): out.append(Reason(level: .critical, text: "SMART 状态：Failing"))
            case Int32(DH_SMART_VERIFIED): out.append(Reason(level: .ok, text: "SMART 状态：Verified"))
            default: break
            }
            return out
        }
        if hasATADetail && !hasNVMeDetail {
            if info.smart_status == Int32(DH_SMART_FAILING) {
                out.append(Reason(level: .critical, text: "设备自报 SMART 阈值超限（Failing）"))
            } else if info.smart_status == Int32(DH_SMART_VERIFIED) {
                out.append(Reason(level: .ok, text: "设备报告 SMART 阈值正常（Verified）"))
            }
            if let count = info.ata_pending_sectors.value, count > 0 {
                out.append(Reason(level: .critical, text: "待映射扇区 \(count) 个"))
            }
            if let count = info.ata_offline_unc.value, count > 0 {
                out.append(Reason(level: .critical, text: "离线无法纠正扇区 \(count) 个"))
            }
            if let count = info.ata_realloc_sectors.value, count > 0 {
                out.append(Reason(level: .warning, text: "已有重映射扇区 \(count) 个"))
            }
            if let tempC, tempC >= 60 {
                out.append(Reason(level: .warning, text: "温度偏高（\(tempC)°C）"))
            }
            if let count = info.ata_crc_errors.value, count > 50 {
                out.append(Reason(level: .warning, text: "UDMA CRC 错误较多（\(count)，多为线缆/桥接问题）"))
            }
            return out
        }
        // NVMe
        if info.critical_warning != 0 {
            out.append(Reason(level: .critical, text: "控制器临界警告位已置位 (0x\(String(info.critical_warning, radix: 16)))"))
        }
        if info.spare < info.spare_threshold {
            if info.spare_threshold <= 30 {
                out.append(Reason(level: .critical, text: "可用备件 \(info.spare)% 已低于阈值 \(info.spare_threshold)%"))
            } else {
                // Apple 内置盘等把阈值设在 99% 的特殊情形：备件在 99/100% 间正常波动，
                // 以控制器自评（临界警告位）为准，这里仅温和提示
                out.append(Reason(level: .warning, text: "可用备件计数低于参考值（\(info.spare)% / \(info.spare_threshold)%）"))
            }
        } else if info.spare_threshold <= 30 && info.spare < info.spare_threshold * 2 {
            out.append(Reason(level: .warning, text: "可用备件 \(info.spare)% 接近阈值 \(info.spare_threshold)%"))
        }
        if info.percentage_used >= 100 {
            out.append(Reason(level: .critical, text: "标称寿命已用尽 (\(info.percentage_used)%)"))
        } else if info.percentage_used >= 80 {
            out.append(Reason(level: .warning, text: "寿命已用 \(info.percentage_used)%（≥80%）"))
        }
        if let tempC, tempC >= 70 {
            out.append(Reason(level: .warning, text: "温度过高（\(tempC)°C）"))
        }
        if info.media_errors > 0 {
            out.append(Reason(level: .warning, text: "累计介质错误 \(info.media_errors) 次"))
        }
        if info.smart_status == Int32(DH_SMART_FAILING) {
            out.append(Reason(level: .critical, text: "SMART 状态：Failing"))
        }
        return out
    }

    // MARK: 展示用格式化

    /// NVMe 数据单元 = 512,000 字节（十进制）
    var readTB: Double { Double(info.data_units_read) * 512_000 / 1e12 }
    var writtenTB: Double { Double(info.data_units_written) * 512_000 / 1e12 }

    /// ATA LBA 扇区 = 512 字节
    var ataReadTB: Double? { info.ata_lba_read.value.map { Double($0) * 512 / 1e12 } }
    var ataWrittenTB: Double? { info.ata_lba_written.value.map { Double($0) * 512 / 1e12 } }

    var powerCycles: UInt64? { hasNVMeDetail ? info.power_cycles : info.ata_power_cycles.value }
    var unsafeShutdowns: UInt64? { hasNVMeDetail ? info.unsafe_shutdowns : info.ata_unsafe_shutdowns.value }

    var sizeText: String {
        guard info.size_bytes > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(info.size_bytes), countStyle: .decimal)
    }

    var powerOnText: String {
        guard let h = hasNVMeDetail ? info.power_on_hours : info.ata_power_on_hours.value else { return "—" }
        if h >= 24 * 365 { return String(format: "%.1f 年（%llu 小时）", Double(h) / 24 / 365, h) }
        return "\(h) 小时"
    }

    var busyText: String {
        guard info.busy_minutes > 0 else { return "—" }
        return String(format: "%.1f 天", Double(info.busy_minutes) / 60 / 24)
    }
}

// C 固定长度 char 数组 → String
func fixedStr<A>(_ tuple: A) -> String {
    var t = tuple
    return withUnsafeBytes(of: &t) { raw in
        String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}

// MARK: - 探测

enum DiskProbe {
    static func run() -> [DiskEntry] {
        var raw = [dh_disk_info_t](repeating: dh_disk_info_t(), count: Int(DH_MAX_DISKS))
        let n = dh_probe_disks(&raw, Int32(DH_MAX_DISKS))
        guard n > 0 else { return [] }

        // 排序：内置盘 → 雷雳/PCIe NVMe → USB 机械盘最后；同级按 BSD 名
        func rank(_ e: DiskEntry) -> Int {
            if e.info.is_internal == 1 { return 0 }
            return e.hasNVMeDetail ? 1 : 2
        }
        return raw.prefix(Int(n)).map(DiskEntry.init)
            .sorted {
                if rank($0) != rank($1) { return rank($0) < rank($1) }
                return $0.bsd < $1.bsd
            }
    }
}
