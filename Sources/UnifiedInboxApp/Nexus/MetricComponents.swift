import Charts
import NexusCore
import SwiftUI

// MARK: - Reusable metric building blocks (dashboard, monitor, widgets, menu bar)

/// Minimal area sparkline. Values are drawn as-is; pass `maxValue` for fixed scales (e.g. 1.0 for %).
struct Sparkline: View {
    let points: [MetricPoint]
    var maxValue: Double? = nil
    var color: Color = Theme.accent

    var body: some View {
        if points.count < 2 {
            Rectangle().fill(.clear)
        } else {
            Chart(points) { p in
                AreaMark(x: .value("Time", p.time), y: .value("Value", p.value))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", p.time), y: .value("Value", p.value))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...(maxValue ?? max(points.map(\.value).max() ?? 1, 1)))
            .accessibilityHidden(true)
        }
    }
}

/// Thin circular gauge (0...1).
struct RingGauge: View {
    let value: Double?
    var color: Color = Theme.accent
    var lineWidth: CGFloat = 5

    var body: some View {
        ZStack {
            Circle().stroke(Theme.fill, lineWidth: lineWidth)
            if let value {
                Circle()
                    .trim(from: 0, to: min(max(value, 0), 1))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: value)
            }
        }
    }
}

/// Large value + label, with an explicit "Unavailable" state (never a fake 0).
struct MetricValue: View {
    let title: String
    let value: String?
    var detail: String? = nil
    var size: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel(text: title)
            Text(value ?? "—")
                .font(.system(size: size, weight: .light, design: .rounded).monospacedDigit())
                .foregroundStyle(value == nil ? Theme.tertiary : Theme.primary)
                .contentTransition(.numericText())
            Text(value == nil ? "Unavailable" : (detail ?? " "))
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value ?? "unavailable"). \(detail ?? "")")
    }
}

/// Glass card wrapping a metric with optional sparkline.
struct MetricCard<Accessory: View>: View {
    let title: String
    let value: String?
    var detail: String? = nil
    var history: [MetricPoint] = []
    var historyMax: Double? = nil
    var tint: Color = Theme.accent
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                MetricValue(title: title, value: value, detail: detail)
                Spacer(minLength: 4)
                accessory()
            }
            if !history.isEmpty {
                Sparkline(points: history, maxValue: historyMax, color: tint).frame(height: 36)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

extension MetricCard where Accessory == EmptyView {
    init(title: String, value: String?, detail: String? = nil, history: [MetricPoint] = [],
         historyMax: Double? = nil, tint: Color = Theme.accent) {
        self.init(title: title, value: value, detail: detail, history: history, historyMax: historyMax, tint: tint) { EmptyView() }
    }
}

// MARK: - Snapshot → display strings

extension SystemSnapshot {
    var cpuText: String? { cpu.map { MetricFormat.percent($0.total) } }

    var memoryText: String? { memory.map { MetricFormat.bytes(Double($0.usedBytes)) } }

    var memoryDetail: String? {
        memory.map { "of \(MetricFormat.bytes(Double($0.totalBytes))) · pressure \($0.pressure.rawValue)" }
    }

    var batteryText: String? {
        switch battery {
        case .reading(let b): return MetricFormat.percent(b.level)
        case .noBattery: return "AC"
        case nil: return nil
        }
    }

    var batteryDetail: String? {
        switch battery {
        case .reading(let b):
            let state = b.isCharging ? "Charging" : (b.onACPower ? "On power adapter" : "On battery")
            if let m = b.minutesRemaining {
                return "\(state) · \(MetricFormat.duration(TimeInterval(m * 60))) \(b.isCharging ? "to full" : "left")"
            }
            return state
        case .noBattery: return "No battery in this Mac"
        case nil: return nil
        }
    }

    var batteryLevel: Double? {
        if case .reading(let b) = battery { return b.level }
        return nil
    }

    var networkText: String? { network.map { "↓ " + MetricFormat.rate($0.downBytesPerSecond) } }
    var networkDetail: String? { network.map { "↑ " + MetricFormat.rate($0.upBytesPerSecond) } }

    var storageText: String? { storage.map { MetricFormat.bytes(Double($0.availableBytes)) } }
    var storageDetail: String? { storage.map { "free of \(MetricFormat.bytes(Double($0.totalBytes)))" } }
}

extension MemoryPressure {
    var color: Color {
        switch self {
        case .normal: return .green.opacity(0.8)
        case .warning: return Theme.warning
        case .critical: return .red
        case .unknown: return Theme.tertiary
        }
    }
}
