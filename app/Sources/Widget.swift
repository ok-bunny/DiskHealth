import SwiftUI
import AppKit
import Combine

// MARK: - 桌面小组件：无边框卡片（原生顺滑拖动、普通窗口层级、所有空间可见）

/// 背景点击交给系统拖动窗口，标题里的原生按钮自行接收点击。
final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

private struct WidgetButton: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let symbol: String
    let label: String
    var highlighted = false
    var angle: Double = 0
    let action: () -> Void

    var body: some View {
        let color: Color = highlighted ? (scheme == .dark ? ResourceMeterColors.darkFill : .accentColor)
                                       : (scheme == .dark ? ResourceMeterColors.darkDetail : ResourceMeterColors.lightDetail)
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(color)
            .rotationEffect(.degrees(angle))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.26), value: angle)
            .accessibilityHidden(true)
            .frame(width: 22, height: 20)
            .overlay { WidgetButtonTarget(label: label, action: action) }
    }
}

// 固定点击区域；动的是 SwiftUI 图标，AppKit 按钮的约束不会跟着旋转。
private struct WidgetButtonTarget: NSViewRepresentable {
    let label: String
    let action: () -> Void

    final class Coordinator: NSObject {
        var action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func performAction() { action() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(action) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.performAction))
        button.isBordered = false
        button.isTransparent = true
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }
}

@MainActor
final class DesktopWidgetController: NSObject {
    static let shared = DesktopWidgetController()
    private var panel: NSPanel?
    private var hosted = false
    private var pendingSize: CGSize?
    private let backdrop = WidgetBackdrop()
    private var backdropObservation: AnyCancellable?
    private var wallpaperTimer: Timer?

    func setVisible(_ on: Bool, store: DiskStore) {
        if on {
            if panel == nil { buildPanel() }
            guard let p = panel else { return }
            if !hosted {
                let host = DraggableHostingView(rootView: WidgetView { [weak self] size in
                    self?.requestPanelSize(size)
                }.environmentObject(store))
                host.sizingOptions = []
                host.safeAreaRegions = []
                p.contentView = WidgetGlassSurface(frame: p.contentView?.bounds ?? .zero, content: host)
                hosted = true
            }
            setAlwaysOnTop(store.widgetAlwaysOnTop)
            p.orderFrontRegardless()
            backdrop.update(for: p)
            if wallpaperTimer == nil {
                wallpaperTimer = Timer.scheduledTimer(timeInterval: 30, target: self, selector: #selector(refreshBackdrop(_:)),
                                                      userInfo: nil, repeats: true)
                wallpaperTimer?.tolerance = 5
            }
        } else {
            panel?.orderOut(nil)
            wallpaperTimer?.invalidate()
            wallpaperTimer = nil
        }
    }

    @objc private func refreshBackdrop(_ sender: Any) {
        if let panel, panel.isVisible { backdrop.update(for: panel) }
    }

    private func requestPanelSize(_ size: CGSize) {
        let alreadyScheduled = pendingSize != nil
        pendingSize = size
        guard !alreadyScheduled else { return }
        // 等当前布局完成后再调整窗口，合并同一帧里多次测量的结果。
        DispatchQueue.main.async { [weak self] in
            guard let self, let size = self.pendingSize, let panel = self.panel else { return }
            self.pendingSize = nil
            let frameSize = panel.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
            let frame = panel.frame
            guard frame.size != frameSize else { return }
            panel.setFrame(NSRect(x: frame.minX, y: frame.maxY - frameSize.height,
                                  width: frameSize.width, height: frameSize.height), display: false)
        }
    }

    func setAlwaysOnTop(_ on: Bool) {
        guard let panel else { return }
        panel.collectionBehavior = on ? [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .canJoinAllApplications]
                                      : [.canJoinAllSpaces, .stationary]
        panel.level = on ? .statusBar : .normal
        if on && panel.isVisible { panel.orderFrontRegardless() }
    }

    private func buildPanel() {
        // 隐藏标题栏，窗口尺寸跟随卡片的实际布局。
        let p = NSPanel(contentRect: NSRect(x: 200, y: 400, width: 254, height: 300),
                        styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.title = "磁盘健康"
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true   // 双保险：AppKit 原生背景拖动
        p.isFloatingPanel = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.setFrameAutosaveName("DiskHealthWidgetFrame")
        panel = p
        backdropObservation = backdrop.$prefersDark.removeDuplicates().sink { [weak p] darkWallpaper in
            p?.appearance = darkWallpaper ? NSAppearance(named: .darkAqua) : nil
        }
        for name in [NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(refreshBackdrop(_:)), name: name, object: p)
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshBackdrop(_:)),
                                                          name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }
}

// MARK: - 小组件内容

struct WidgetView: View {
    @EnvironmentObject var store: DiskStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @AppStorage("dh_widgetCollapsed") private var collapsed = false
    var onSizeChange: (CGSize) -> Void = { _ in }

    private var toggleAnimation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.30) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 4) {
                DiskHealthHeader(disks: store.disks, isRefreshing: store.isRefreshing, compact: true)
                WidgetButton(symbol: store.widgetAlwaysOnTop ? "pin.fill" : "pin",
                             label: store.widgetAlwaysOnTop ? "取消小组件置顶" : "将小组件置顶",
                             highlighted: store.widgetAlwaysOnTop, angle: store.widgetAlwaysOnTop ? 0 : -20) {
                    store.setWidgetAlwaysOnTop(!store.widgetAlwaysOnTop)
                }
                WidgetButton(symbol: "chevron.up",
                             label: collapsed ? "展开小组件" : "收拢小组件", angle: collapsed ? 180 : 0) {
                    collapsed.toggle()
                }
            }
            Divider()
            ResourceSampleHeader(monitor: store.resources)
                .font(.system(size: 10))
            WidgetModesLayout(compactness: collapsed ? 1 : 0) {
                VStack(alignment: .leading, spacing: 7) {
                    ResourceUsageView(monitor: store.resources, compact: true)
                    Divider()
                    diskDetails
                }
                .opacity(collapsed ? 0 : 1)
                .accessibilityHidden(collapsed)
                .allowsHitTesting(!collapsed)
                WidgetResourceRings(monitor: store.resources)
                    .opacity(collapsed ? 1 : 0)
                    .accessibilityHidden(!collapsed)
                    .allowsHitTesting(collapsed)
            }
            .clipped()
            .animation(toggleAnimation, value: collapsed)
        }
        .padding(12)
        .frame(width: 230)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(scheme == .dark ? ResourceMeterColors.darkPrimary : Color.primary)
        .help("拖动移动")
        .onGeometryChange(for: CGSize.self) { proxy in
            CGSize(width: ceil(proxy.size.width), height: ceil(proxy.size.height))
        } action: { size in
            onSizeChange(size)
        }
        // 动画中的内容可暂时高于当前窗口；始终从左上角向下揭开。
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    @ViewBuilder
    private var diskDetails: some View {
        ForEach(store.disks) { disk in
            HStack(spacing: 6) {
                Circle().fill(color(for: disk.health)).frame(width: 6, height: 6)
                Text(disk.displayName)
                    .font(.system(size: 10))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if let tempC = disk.tempC {
                    Text("\(tempC)°C")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(tempC >= 70 ? .red : (tempC >= 60 ? .orange : .primary))
                }
            }
        }
        Divider()
        // 存储使用量：按存储单元（RAID 集 / 独立卷），不按物理盘
        ForEach(store.volumes) { unit in
            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    Text(unit.name)
                        .font(.system(size: 10))
                        .lineLimit(1).truncationMode(.middle)
                    Text(unit.isInternal ? "内置" : "")
                        .font(.system(size: 8))
                        .foregroundStyle(scheme == .dark ? ResourceMeterColors.darkDetail : ResourceMeterColors.lightDetail)
                    Spacer()
                    Text("\(Int(unit.fraction * 100))%")
                        .font(.system(size: 10).monospacedDigit().weight(.semibold))
                        .foregroundStyle(unit.fraction >= 0.95 ? .red :
                                         (unit.fraction >= 0.8 ? .orange : .primary))
                }
                HStack(spacing: 4) {
                    let fill: Color = unit.fraction >= 0.95 ? .red : (unit.fraction >= 0.8 ? .orange :
                        (scheme == .dark ? ResourceMeterColors.darkFill : .accentColor))
                    if scheme == .dark {
                        DarkResourceMeterBar(fraction: unit.fraction, fill: fill).frame(height: 12)
                    } else {
                        ProgressView(value: unit.fraction).tint(fill)
                    }
                    Text("\(unit.usedText) / \(unit.totalText)")
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(scheme == .dark ? ResourceMeterColors.darkDetail : ResourceMeterColors.lightDetail)
                        .fixedSize()
                }
            }
        }
        Divider()
        HStack {
            Text(store.lastRefresh.map { "磁盘更新 " + $0.formatted(date: .omitted, time: .shortened) } ?? "磁盘未更新")
            Spacer()
            if store.isRefreshing {
                Text("刷新中…")
            }
        }
        .font(.system(size: 9))
        .foregroundStyle(scheme == .dark ? ResourceMeterColors.darkDetail : ResourceMeterColors.lightDetail)
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

/// 两种布局都以实际内容测量。窗口高度和内容淡化使用同一个可反向的动画。
private struct WidgetModesLayout: Layout {
    var compactness: CGFloat
    var animatableData: CGFloat {
        get { compactness }
        set { compactness = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let natural = ProposedViewSize(width: proposal.width, height: nil)
        let expanded = subviews[0].sizeThatFits(natural)
        let compact = subviews[1].sizeThatFits(natural)
        return CGSize(width: max(expanded.width, compact.width),
                      height: expanded.height + (compact.height - expanded.height) * compactness)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let natural = ProposedViewSize(width: bounds.width, height: nil)
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading, proposal: natural)
        }
    }
}
