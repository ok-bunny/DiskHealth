import SwiftUI

struct WidgetResourceRings: View {
    @ObservedObject var monitor: ResourceMonitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            ring("CPU", fraction: monitor.cpuUsage)
            ring("内存", fraction: monitor.memory?.fraction, detail: monitor.memory?.capacityText)
            if let swap = monitor.swap, swap.totalBytes > 0 {
                ring("Swap", fraction: swap.fraction, percent: swap.swapPercentText, detail: swap.capacityText)
            } else {
                ring("Swap", fraction: nil, detail: monitor.swap == nil ? nil : "尚未分配")
            }
        }
        .font(.system(size: 10))
    }

    private func ring(_ name: String, fraction: Double?, percent: String? = nil,
                      detail: String? = nil) -> some View {
        let value = percent ?? fraction?.formatted(.percent.precision(.fractionLength(0))) ?? "—"
        return VStack(spacing: 3) {
            ZStack {
                Circle().strokeBorder(scheme == .dark ? ResourceMeterColors.darkTrack : Color.secondary.opacity(0.25),
                                      lineWidth: 4)
                if let fraction {
                    let progress = min(max(fraction, 0), 1)
                    Circle().inset(by: 2)
                        .trim(from: 0, to: progress)
                        .stroke(scheme == .dark ? ResourceMeterColors.darkFill : Color.accentColor,
                                style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: progress)
                }
                Text(verbatim: value)
                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
            }
            .frame(width: 48, height: 48)
            Text(verbatim: name).fontWeight(.semibold)
            if let detail {
                ViewThatFits(in: .horizontal) {
                    Text(verbatim: detail).fixedSize()
                    Text(verbatim: detail.replacingOccurrences(of: " / ", with: " /\n"))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(scheme == .dark ? ResourceMeterColors.darkDetail : ResourceMeterColors.lightDetail)
                .multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(scheme == .dark ? ResourceMeterColors.darkPrimary : Color.primary)
        .frame(minWidth: 0, maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityValue(Text(verbatim: [value, detail].compactMap { $0 }.joined(separator: "，")))
    }
}
