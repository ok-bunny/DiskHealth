import SwiftUI
import AppKit

// MARK: - 数据中心：探测磁盘（自动刷新默认关闭，可手动刷新）

@MainActor
final class DiskStore: ObservableObject {
    let resources = ResourceMonitor()
    @Published var disks: [DiskEntry] = []
    @Published var volumes: [StorageUnit] = []
    @Published var lastRefresh: Date?
    @Published var isRefreshing = false
    @Published var expanded = Set<String>()   // 展开详情的磁盘 id（避开 @State 宏）

    // 设置（UserDefaults 持久化，手动 setter 写入，避免 init 触发副作用）
    @Published private(set) var autoRefresh: Bool
    @Published private(set) var refreshInterval: TimeInterval
    @Published private(set) var widgetVisible: Bool
    @Published private(set) var widgetAlwaysOnTop: Bool

    private var timer: Timer?
    private let d = UserDefaults.standard

    var overall: HealthLevel {
        disks.map(\.health).max() ?? .unknown
    }

    init() {
        autoRefresh = (d.object(forKey: "dh_autoRefresh") as? Bool) ?? false
        refreshInterval = (d.object(forKey: "dh_interval") as? Double) ?? 60
        widgetVisible = d.bool(forKey: "dh_widgetVisible")
        widgetAlwaysOnTop = d.bool(forKey: "dh_widgetAlwaysOnTop")
        refresh()
        // 启动时恢复桌面小组件（等 AppKit 就绪）
        let restore = widgetVisible
        Task { @MainActor [weak self] in
            guard let self else { return }
            DesktopWidgetController.shared.setVisible(restore, store: self)
        }
    }

    func setAutoRefresh(_ on: Bool) {
        autoRefresh = on
        d.set(on, forKey: "dh_autoRefresh")
        scheduleNext()
    }

    func setRefreshInterval(_ t: TimeInterval) {
        refreshInterval = t
        d.set(t, forKey: "dh_interval")
        if autoRefresh { scheduleNext() }
    }

    func setWidgetVisible(_ on: Bool) {
        widgetVisible = on
        d.set(on, forKey: "dh_widgetVisible")
        DesktopWidgetController.shared.setVisible(on, store: self)
    }

    func setWidgetAlwaysOnTop(_ on: Bool) {
        widgetAlwaysOnTop = on
        d.set(on, forKey: "dh_widgetAlwaysOnTop")
        DesktopWidgetController.shared.setAlwaysOnTop(on)
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        timer?.invalidate()
        Task.detached(priority: .utility) { [weak self] in
            let result = DiskProbe.run()
            let vols = VolumeProbe.run()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.disks = result
                self.volumes = vols
                self.lastRefresh = Date()
                self.isRefreshing = false
                self.scheduleNext()
            }
        }
    }

    private func scheduleNext() {
        timer?.invalidate()
        timer = nil
        guard autoRefresh, !isRefreshing else { return }
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: false) { [weak self] _ in
            // 该定时器注册在主线程的 RunLoop，直接处理可避免已取消的刷新再次入队。
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
}

// MARK: - 菜单栏应用入口

@main
struct DiskHealthApp: App {
    @StateObject private var store = DiskStore()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(store)
        } label: {
            switch store.overall {
            case .critical:
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .foregroundStyle(.red)
            case .warning:
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .foregroundStyle(.yellow)
            default:
                Image(systemName: "externaldrive")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
