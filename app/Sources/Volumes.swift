import Foundation
import Darwin
import DiskArbitration

// MARK: - 存储使用量：按"存储单元"聚合（RAID 集合 / APFS 容器 / 独立盘各算一个整体）

struct StorageUnit: Identifiable {
    let id: String          // APFS 容器或独立卷的 BSD 设备名
    let name: String
    let totalBytes: Int64
    let freeBytes: Int64
    let isInternal: Bool

    var usedBytes: Int64 { max(totalBytes - freeBytes, 0) }
    var fraction: Double { totalBytes > 0 ? min(Double(usedBytes) / Double(totalBytes), 1) : 0 }
    var usedText: String { ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .decimal) }
    var totalText: String { ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .decimal) }
}

enum VolumeProbe {

    static func run() -> [StorageUnit] {
        var count = getfsstat(nil, 0, 0)
        guard count > 0 else { return [] }
        let buf = UnsafeMutablePointer<statfs>.allocate(capacity: Int(count))
        defer { buf.deallocate() }
        count = getfsstat(buf, Int32(MemoryLayout<statfs>.stride) * count, MNT_NOWAIT)
        guard count > 0 else { return [] }

        struct Vol {
            let mount: String
            let device: String
            let total: Int64
            let free: Int64
            let apfs: Bool
        }
        var vols: [Vol] = []
        for i in 0..<Int(count) {
            let fs = buf[i]
            let type = tupleStr(fs.f_fstypename)
            guard type == "apfs" || type == "hfs" else { continue }
            let mount = tupleStr(fs.f_mntonname)
            // 只看用户可见的本地挂载点：根目录 + /Volumes 下非隐藏、非系统辅助卷
            let sysRoles: Set<String> = ["Recovery", "Preboot", "VM", "iSCPreboot", "Update (Macintosh HD)"]
            let lastComp = (mount as NSString).lastPathComponent
            guard mount == "/" || (mount.hasPrefix("/Volumes/") &&
                   !lastComp.hasPrefix(".") && !sysRoles.contains(lastComp)) else { continue }
            let device = tupleStr(fs.f_mntfromname)
            guard device.hasPrefix("/dev/disk") else { continue }
            let total = Int64(clamping: UInt64(fs.f_blocks) * UInt64(fs.f_bsize))
            let free = Int64(clamping: UInt64(fs.f_bavail) * UInt64(fs.f_bsize))
            vols.append(Vol(mount: mount, device: device, total: total, free: free, apfs: type == "apfs"))
        }
        guard !vols.isEmpty else { return [] }

        // APFS 的卷和快照共享容器空间；HFS+ 的每个分区都有自己的容量。
        let groups = Dictionary(grouping: vols) { volume in
            let bsd = String(volume.device.dropFirst("/dev/".count))
            guard volume.apfs, let container = bsd.range(of: #"^disk\d+"#, options: .regularExpression)
            else { return bsd }
            return String(bsd[container])
        }

        let fm = FileManager.default
        let session = DASessionCreate(kCFAllocatorDefault)
        var units: [StorageUnit] = []
        for (dev, members) in groups {
            // APFS 容器内多卷共享空间：总量取最大、可用取最小，避免重复计数
            let total = members.map(\.total).max() ?? 0
            let free = members.map(\.free).min() ?? 0

            let names = members.map { m in
                m.mount == "/" ? (fm.displayName(atPath: "/") == "/" ? "Macintosh HD" : fm.displayName(atPath: "/"))
                                : (m.mount as NSString).lastPathComponent
            }
            var uniq: [String] = []
            for n in names where !uniq.contains(n) { uniq.append(n) }
            let name = uniq.joined(separator: " + ")

            var isInternalUnit = members.contains { $0.mount == "/" }
            if let session,
               let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, "/dev/\(dev)"),
               let desc = DADiskCopyDescription(disk) as? [String: Any],
               (desc["DADeviceInternal"] as? Bool) == true {
                isInternalUnit = true
            }
            units.append(StorageUnit(id: dev, name: name.isEmpty ? dev : name,
                                     totalBytes: total, freeBytes: free, isInternal: isInternalUnit))
        }
        return units.sorted {
            if $0.isInternal != $1.isInternal { return $0.isInternal }
            return $0.name < $1.name
        }
    }
}

private func tupleStr<A>(_ tuple: A) -> String {
    var t = tuple
    return withUnsafeBytes(of: &t) { raw in
        String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}
