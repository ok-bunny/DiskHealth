import Foundation
import Combine

@MainActor
final class ResourceMonitor: ObservableObject {
    @Published private(set) var cpuUsage: Double?
    @Published private(set) var memory: MemoryUsage?
    @Published private(set) var swap: MemoryUsage?
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var autoRefresh: Bool

    private let defaults: UserDefaults
    private let autoRefreshKey = "dh_resourceAutoRefresh"
    private var samplingTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoRefresh = defaults.bool(forKey: autoRefreshKey)
        refresh()
    }

    deinit { samplingTask?.cancel() }

    func setAutoRefresh(_ on: Bool) {
        guard on != autoRefresh else { return }
        autoRefresh = on
        defaults.set(on, forKey: autoRefreshKey)
        if on {
            refresh()
        } else {
            samplingTask?.cancel()
            isRefreshing = false
        }
    }

    func refresh() {
        samplingTask?.cancel()
        isRefreshing = true
        samplingTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            var previous = SystemProbe.cpuTicks()
            // 单次刷新也需要两个采样点，以免显示从开机起的平均占用率。
            var interval = Duration.milliseconds(500)
            var firstSampleRetries = 3
            while true {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, !Task.isCancelled else { return }
                let current = SystemProbe.cpuTicks()
                let usage = previous.flatMap { current?.usage(since: $0) }
                // 系统可能短暂返回相同的计数。首个读数最多等两秒，并保留有效基线。
                if usage == nil && firstSampleRetries > 0 {
                    firstSampleRetries -= 1
                    previous = previous ?? current
                    continue
                }
                self.cpuUsage = usage
                self.memory = SystemProbe.memory()
                self.swap = SystemProbe.swap()
                self.lastRefresh = Date()
                self.isRefreshing = false
                guard self.autoRefresh else { return }
                firstSampleRetries = 0
                previous = current
                interval = .seconds(2)
            }
        }
    }
}
