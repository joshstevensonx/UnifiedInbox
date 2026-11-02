import Charts
import NexusCore
import SwiftUI

/// System Monitor: per-metric tabs with labelled charts (units, time axis, missing-data state).
struct MonitorView: View {
    @EnvironmentObject private var monitor: SystemMonitor

    enum Tab: String, CaseIterable, Identifiable {
        case cpu = "CPU", memory = "Memory", network = "Network", battery = "Battery", storage = "Storage"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .cpu

    var body: some View {
        let s = monitor.snapshot
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 460)
                Spacer()
                Toggle(isOn: $monitor.isPaused) { Label("Pause", systemImage: "pause.fill") }
                    .toggleStyle(.button)
                    .help("Pause all sampling (widgets keep their last values, marked stale)")
                Text("Last 5 min · \(timeText(s.timestamp))")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }

            switch tab {
            case .cpu:
                stats([("Total", s.cpuText), ("User", s.cpu.map { MetricFormat.percent($0.user) }),
                       ("System", s.cpu.map { MetricFormat.percent($0.system) }), ("Cores", "\(monitor.identity.cpuCount)")])
                MetricChart(series: [("CPU", monitor.cpuHistory, Theme.accent)], unit: .percent)
            case .memory:
                stats([("Used", s.memoryText), ("Total", s.memory.map { MetricFormat.bytes(Double($0.totalBytes)) }),
                       ("Wired", s.memory.map { MetricFormat.bytes(Double($0.wiredBytes)) }),
                       ("Compressed", s.memory.map { MetricFormat.bytes(Double($0.compressedBytes)) }),
                       ("Pressure", s.memory?.pressure.rawValue.capitalized)])
                MetricChart(series: [("Memory", monitor.memoryHistory, .purple.opacity(0.8))], unit: .percent)
            case .network:
                stats([("Download", s.network.map { MetricFormat.rate($0.downBytesPerSecond) }),
                       ("Upload", s.network.map { MetricFormat.rate($0.upBytesPerSecond) })])
                MetricChart(series: [("Download", monitor.downHistory, Theme.accent),
                                     ("Upload", monitor.upHistory, .orange.opacity(0.85))], unit: .rate)
            case .battery:
                stats([("Charge", s.batteryText), ("State", s.batteryDetail)])
                placeholder("Battery history is sampled every 30 s and isn't charted yet.")
            case .storage:
                stats([("Free", s.storageText), ("Total", s.storage.map { MetricFormat.bytes(Double($0.totalBytes)) }),
                       ("Used", s.storage.map { MetricFormat.percent($0.usedFraction) })])
                placeholder("Startup disk only. Other volumes will be added later.")
            }
            Spacer(minLength: 0)
        }
        .padding(28)
        .navigationTitle("System Monitor")
        .onAppear { monitor.subscribe() }
        .onDisappear { monitor.unsubscribe() }
    }

    private func stats(_ items: [(String, String?)]) -> some View {
        HStack(spacing: 28) {
            ForEach(items, id: \.0) { MetricValue(title: $0.0, value: $0.1, size: 24) }
            Spacer()
        }
        .padding(18)
        .glassCard()
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            .frame(maxWidth: .infinity, minHeight: 120).glassCard()
    }

    private func timeText(_ d: Date) -> String {
        d == .distantPast ? "waiting for first sample" : "updated " + d.formatted(date: .omitted, time: .standard)
    }
}

/// Labelled line chart with time axis and units; shows an explicit empty state.
struct MetricChart: View {
    enum Unit { case percent, rate }
    let series: [(name: String, points: [MetricPoint], color: Color)]
    let unit: Unit

    var body: some View {
        Group {
            if series.allSatisfy({ $0.points.count < 2 }) {
                Text("Collecting data…").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart {
                    ForEach(series, id: \.name) { s in
                        ForEach(s.points) { p in
                            LineMark(x: .value("Time", p.time), y: .value("Value", p.value))
                                .foregroundStyle(by: .value("Series", s.name))
                                .interpolationMethod(.monotone)
                        }
                    }
                }
                .chartForegroundStyleScale(domain: series.map(\.name), range: series.map(\.color))
                .chartYScale(domain: unit == .percent ? 0...1 : 0...max(series.flatMap { $0.points.map(\.value) }.max() ?? 1, 1))
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(Theme.hairline)
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(unit == .percent ? MetricFormat.percent(v) : MetricFormat.rate(v))
                                    .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .minute)) { _ in
                        AxisGridLine().foregroundStyle(Theme.hairline)
                        AxisValueLabel(format: .dateTime.hour().minute()).foregroundStyle(Theme.tertiary)
                    }
                }
                .chartLegend(series.count > 1 ? .visible : .hidden)
            }
        }
        .padding(18)
        .frame(minHeight: 260)
        .glassCard()
    }
}
