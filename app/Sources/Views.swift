import SwiftUI
import AppKit

// MARK: - 主面板

struct ContentView: View {
    @EnvironmentObject var store: DiskStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ResourceUsageView(monitor: store.resources)
                .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            ScrollView {
                VStack(spacing: 10) {
                    if store.disks.isEmpty {
                        emptyView
                    } else {
                        ForEach(store.disks) { DiskCard(entry: $0) }
                    }
                }
                .padding(12)
            }
            Divider()
            footer
        }
        .frame(width: 400, height: 560)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            DiskHealthHeader(disks: store.disks, isRefreshing: store.isRefreshing)
            if store.isRefreshing {
                ProgressView().controlSize(.small)
            } else if let t = store.lastRefresh {
                Text(t.formatted(.relative(presentation: .named)))
                    .font(.caption).foregroundStyle(.secondary).fixedSize()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text("未发现物理磁盘").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }

    private var footer: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Toggle("磁盘自动刷新",
                       isOn: Binding(get: { store.autoRefresh }, set: { store.setAutoRefresh($0) }))
                    .toggleStyle(.switch).controlSize(.mini)
                Picker("间隔", selection: Binding(get: { store.refreshInterval },
                                                  set: { store.setRefreshInterval($0) })) {
                    Text("10 秒").tag(TimeInterval(10))
                    Text("30 秒").tag(TimeInterval(30))
                    Text("1 分钟").tag(TimeInterval(60))
                    Text("5 分钟").tag(TimeInterval(300))
                    Text("1 小时").tag(TimeInterval(3600))
                }
                .pickerStyle(.menu).frame(width: 96)
                .disabled(!store.autoRefresh)
                Spacer()
            }
            .font(.caption)
            HStack(spacing: 10) {
                Button {
                    store.refresh()
                } label: {
                    Label("刷新磁盘", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)
                Toggle("桌面小组件",
                       isOn: Binding(get: { store.widgetVisible }, set: { store.setWidgetVisible($0) }))
                    .toggleStyle(.switch).controlSize(.mini)
                Spacer()
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Text("退出")
                }
            }
            .font(.caption)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

}

struct DiskHealthHeader: View {
    let disks: [DiskEntry]
    let isRefreshing: Bool
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(DiskHealthSummaryLine.lines(for: disks, isRefreshing: isRefreshing)) { line in
                HStack(alignment: .firstTextBaseline, spacing: compact ? 6 : 8) {
                    Circle().fill(color(for: line.level))
                        .frame(width: compact ? 8 : 10, height: compact ? 8 : 10)
                        .accessibilityHidden(true)
                    Text(verbatim: line.title)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityHint(Text(verbatim: line.details))
                }
                .help(line.details)
            }
        }
        .font(compact ? .system(size: 11, weight: .bold) : .headline)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func color(for level: HealthLevel) -> Color {
        switch level {
        case .ok: return .green
        case .warning: return .yellow
        case .critical: return .red
        case .unknown: return .gray
        }
    }
}

// MARK: - CPU、内存与交换空间

enum ResourceMeterColors {
    static let lightDetail = Color(.sRGB, red: 0.24, green: 0.26, blue: 0.29)
    static let darkFill = Color(.sRGB, red: 0.65, green: 0.92, blue: 0.85)
    static let darkTrack = Color(.sRGB, red: 0.45, green: 0.46, blue: 0.47)
    static let darkPrimary = Color(.sRGB, red: 0.96, green: 0.97, blue: 0.98)
    static let darkDetail = Color(.sRGB, red: 0.82, green: 0.84, blue: 0.85)
}

struct DarkResourceMeterBar: View {
    let fraction: Double
    var fill = ResourceMeterColors.darkFill

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(ResourceMeterColors.darkTrack)
                Capsule().fill(fill)
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 4)
    }
}

extension MemoryUsage {
    var capacityText: String {
        let used = usedBytes == 0 ? "0 B" :
            ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .memory)
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .memory)
        return "\(used) / \(total)"
    }

    var swapPercentText: String {
        fraction > 0 && fraction < 0.001
            ? "<0.1%" : fraction.formatted(.percent.precision(.fractionLength(0...1)))
    }
}

struct ResourceSampleHeader: View {
    @ObservedObject var monitor: ResourceMonitor
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack {
            Text("系统资源").fontWeight(.semibold)
                .foregroundStyle(scheme == .dark ? ResourceMeterColors.darkPrimary : Color.primary)
            Spacer()
            Text(sampleStatus).monospacedDigit()
                .foregroundStyle(scheme == .dark ? ResourceMeterColors.darkDetail : ResourceMeterColors.lightDetail)
        }
    }

    private var sampleStatus: String {
        if monitor.isRefreshing { return "采样中…" }
        guard let date = monitor.lastRefresh else { return "暂无采样" }
        let time = date.formatted(date: .omitted, time: .standard)
        return monitor.autoRefresh ? "采样 \(time)" : "已暂停 · \(time)"
    }
}

struct ResourceUsageView: View {
    @ObservedObject var monitor: ResourceMonitor
    @Environment(\.colorScheme) private var scheme
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            if !compact { ResourceSampleHeader(monitor: monitor) }
            metric("CPU", fraction: monitor.cpuUsage)
            metric("内存", fraction: monitor.memory?.fraction, detail: monitor.memory?.capacityText)
            swapMetric
                .help("Swap 交换空间用量，显示已用容量 / 系统已分配容量")
            if !compact {
                HStack {
                    Toggle("每 2 秒刷新 CPU、内存和交换空间", isOn: Binding(
                        get: { monitor.autoRefresh }, set: { monitor.setAutoRefresh($0) }))
                        .toggleStyle(.switch).controlSize(.mini)
                    Spacer()
                    Button("刷新一次") { monitor.refresh() }
                        .controlSize(.small)
                        .disabled(monitor.isRefreshing)
                        .help("立即采样 CPU、内存和交换空间")
                }
            }
        }
        .font(compact ? .system(size: 10) : .caption)
    }

    @ViewBuilder
    private var swapMetric: some View {
        let label = compact ? "Swap" : "交换空间（Swap）"
        if let swap = monitor.swap, swap.totalBytes > 0 {
            metric(label, fraction: swap.fraction, detail: swap.capacityText, valueText: swap.swapPercentText)
        } else {
            metric(label, fraction: nil, valueText: monitor.swap == nil ? "—" : "尚未分配")
        }
    }

    private func metric(_ name: String, fraction: Double?, detail: String? = nil,
                        valueText: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(name)
                if let detail {
                    Text(detail).monospacedDigit()
                        .foregroundStyle(scheme == .dark ? ResourceMeterColors.darkDetail : ResourceMeterColors.lightDetail)
                }
                Spacer()
                Text(valueText ?? fraction.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—")
                    .monospacedDigit()
            }
            .foregroundStyle(scheme == .dark ? ResourceMeterColors.darkPrimary : Color.primary)
            if let fraction {
                if scheme == .dark {
                    DarkResourceMeterBar(fraction: fraction).frame(height: 12).accessibilityHidden(true)
                } else {
                    ProgressView(value: fraction).controlSize(.mini).accessibilityHidden(true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 磁盘卡片

struct DiskCard: View {
    let entry: DiskEntry
    @EnvironmentObject private var store: DiskStore

    private var expanded: Binding<Bool> {
        Binding(
            get: { store.expanded.contains(entry.id) },
            set: { on in
                if on { store.expanded.insert(entry.id) } else { store.expanded.remove(entry.id) }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.displayName.isEmpty ? entry.bsd : entry.displayName)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text(entry.bsd)
                        if entry.info.is_internal == 1 { Text("内置") } else { Text("外接") }
                        if !entry.transport.isEmpty { Text(entry.transport) }
                        if !entry.sizeText.isEmpty && entry.sizeText != "—" { Text(entry.sizeText) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(entry.health.label)
                        .font(.caption.weight(.bold)).foregroundStyle(statusColor)
                    if let tempC = entry.tempC {
                        Text("\(tempC)°C")
                            .font(.system(.title3, design: .rounded).monospacedDigit())
                            .foregroundStyle(tempC >= 70 ? .red : (tempC >= 60 ? .orange : .primary))
                    }
                }
            }

            if entry.hasNVMeDetail {
                // 寿命/备件进度
                VStack(spacing: 4) {
                    meter(label: "已用寿命", value: Double(min(entry.info.percentage_used, 100)),
                          display: "\(entry.info.percentage_used)%")
                    meter(label: "可用备件", value: Double(entry.info.spare),
                          display: "\(entry.info.spare)% / 阈值 \(entry.info.spare_threshold)%")
                }
            }

            if !entry.healthReasons.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(entry.healthReasons, id: \.self) { r in
                        Label(r, systemImage: entry.health >= .warning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(entry.health >= .warning ? .orange : .secondary)
                    }
                }
            }

            if entry.smartDetailUnavailable {
                Label("未取得可用的 SMART 数据", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }

            DisclosureGroup(isExpanded: expanded) {
                detail
            } label: {
                Text("详细数据").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.background.secondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(entry.health >= .warning ? statusColor.opacity(0.5) : Color.gray.opacity(0.2),
                              lineWidth: entry.health >= .warning ? 1.5 : 1)
        )
    }

    private func meter(label: String, value: Double, display: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption2).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
            ProgressView(value: min(value, 100), total: 100)
                .tint(label.contains("备件") ? (value < 20 ? .red : .green) : (value >= 80 ? .orange : .green))
            Text(display).font(.caption2.monospacedDigit()).frame(width: 110, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 3) {
            if entry.hasNVMeDetail {
                row("序列号", entry.serial.isEmpty ? "—" : entry.serial)
                row("固件", entry.firmware.isEmpty ? "—" : entry.firmware)
                row("累计读取", String(format: "%.2f TB", entry.readTB))
                row("累计写入", String(format: "%.2f TB", entry.writtenTB))
                row("通电时间", entry.powerOnText)
                row("通电次数", entry.powerCycles.map { "\($0) 次" } ?? "—")
                row("异常断电", entry.unsafeShutdowns.map { "\($0) 次" } ?? "—")
                row("控制器繁忙", entry.busyText)
                row("介质错误", entry.info.media_errors == 0 ? "0（正常）" : "\(entry.info.media_errors)")
                row("错误日志条目", "\(entry.info.error_log_entries)")
                row("主机读/写命令", "\(entry.info.host_read_cmds) / \(entry.info.host_write_cmds)")
                row("临界警告位", entry.info.critical_warning == 0 ? "0x00（正常）" : "0x\(String(entry.info.critical_warning, radix: 16))")
            } else if entry.hasATADetail {
                row("序列号", entry.serial.isEmpty ? "—" : entry.serial)
                row("固件", entry.firmware.isEmpty ? "—" : entry.firmware)
                row("SMART 结论", smartStatusText)
                row("累计读取", entry.ataReadTB.map { String(format: "%.2f TB", $0) } ?? "—")
                row("累计写入", entry.ataWrittenTB.map { String(format: "%.2f TB", $0) } ?? "—")
                row("通电时间", entry.powerOnText)
                row("通电次数", entry.powerCycles.map { "\($0) 次" } ?? "—")
                row("异常断电", entry.unsafeShutdowns.map { "\($0) 次" } ?? "—")
                row("重映射扇区", sectorCount(entry.info.ata_realloc_sectors))
                row("待映射扇区", sectorCount(entry.info.ata_pending_sectors))
                row("离线坏扇区", sectorCount(entry.info.ata_offline_unc))
                row("UDMA CRC 错误", entry.info.ata_crc_errors.value.map(String.init) ?? "—")
            } else {
                row("序列号", entry.serial.isEmpty ? "—" : entry.serial)
                row("固件", entry.firmware.isEmpty ? "—" : entry.firmware)
                row("SMART 状态", smartStatusText)
                Text("未取得可识别的 SMART 明细")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 4)
    }

    private func sectorCount(_ attribute: dh_ata_value_t) -> String {
        guard let value = attribute.value else { return "—" }
        return value == 0 ? "0（正常）" : String(value)
    }

    private var smartStatusText: String {
        switch entry.info.smart_status {
        case Int32(DH_SMART_VERIFIED): return "Verified（正常）"
        case Int32(DH_SMART_FAILING): return "Failing（故障）"
        default: return "不可读"
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.caption2.monospacedDigit())
        }
    }

    private var statusColor: Color {
        switch entry.health {
        case .ok: return .green
        case .warning: return .yellow
        case .critical: return .red
        case .unknown: return .gray
        }
    }
}
