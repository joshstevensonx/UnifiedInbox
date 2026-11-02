import AppKit
import Combine
import NexusCore

/// The one shared monitoring coordinator (spec §5.3, §7, §12).
///
/// - Samples on a private serial queue — never on the main thread or inside views.
/// - Publishes immutable `SystemSnapshot`s plus bounded history on the main actor.
/// - CPU / memory / network every 2 s while something is watching, every 15 s otherwise;
///   battery every ~30 s, storage every ~60 s.
/// - Pauses on sleep and resets deltas on wake so there's no bogus spike.
@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var snapshot = SystemSnapshot(timestamp: .distantPast)
    @Published private(set) var cpuHistory: [MetricPoint] = []
    @Published private(set) var memoryHistory: [MetricPoint] = []
    @Published private(set) var downHistory: [MetricPoint] = []
    @Published private(set) var upHistory: [MetricPoint] = []
    @Published var isPaused = false { didSet { reschedule() } }

    let identity = SystemSampler.identity()

    static let historyCapacity = 150 // 5 minutes at 2 s
    private var cpuRing = RingBuffer<MetricPoint>(capacity: historyCapacity)
    private var memRing = RingBuffer<MetricPoint>(capacity: historyCapacity)
    private var downRing = RingBuffer<MetricPoint>(capacity: historyCapacity)
    private var upRing = RingBuffer<MetricPoint>(capacity: historyCapacity)

    private let queue = DispatchQueue(label: "nexus.monitor", qos: .utility)
    private let sampler = SystemSampler()   // only touched on `queue`
    private var timer: DispatchSourceTimer?
    private var subscribers = 0
    private var sleeping = false
    private var observers: [NSObjectProtocol] = []

    var interval: TimeInterval { subscribers > 0 ? 2 : 15 }

    init() {
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = true; self?.reschedule() }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sleeping = false
                let sampler = self.sampler
                self.queue.async { sampler.resetBaselines() }
                self.reschedule()
            }
        })
        reschedule()
    }

    deinit {
        timer?.cancel()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    // MARK: Demand

    /// Views and widgets call these in onAppear / onDisappear; fast sampling only while watched.
    func subscribe() {
        subscribers += 1
        if subscribers == 1 { reschedule(); sampleNow() }
    }

    func unsubscribe() {
        subscribers = max(0, subscribers - 1)
        if subscribers == 0 { reschedule() }
    }

    // MARK: Sampling

    private func reschedule() {
        timer?.cancel()
        timer = nil
        guard !isPaused, !sleeping else { return }
        timer = Self.makeTimer(queue: queue, interval: interval, sampler: sampler) { [weak self] snap in
            Task { @MainActor in self?.publish(snap) }
        }
    }

    /// Built outside the main actor so the handler runs purely on `queue`; the tick counter lives there too.
    nonisolated private static func makeTimer(queue: DispatchQueue, interval: TimeInterval, sampler: SystemSampler,
                                              publish: @escaping @Sendable (SystemSnapshot) -> Void) -> DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(250))
        let every = max(1, Int(30 / interval)) // battery ≈ every 30 s, storage ≈ every 60 s
        var tick = 0
        t.setEventHandler {
            tick += 1
            publish(sample(sampler, battery: tick % every == 0, storage: tick % (every * 2) == 0))
        }
        t.resume()
        return t
    }

    func sampleNow() {
        let sampler = self.sampler
        queue.async { [weak self] in
            let snap = Self.sample(sampler, battery: true, storage: true)
            Task { @MainActor in self?.publish(snap) }
        }
    }

    /// Runs on `queue`. `nil` fields keep the previous value for slow metrics (see `publish`).
    nonisolated private static func sample(_ s: SystemSampler, battery: Bool, storage: Bool) -> SystemSnapshot {
        SystemSnapshot(
            timestamp: Date(),
            cpu: s.cpu(),
            memory: s.memory(),
            battery: battery ? s.battery() : nil,
            network: s.network(),
            storage: storage ? s.storage() : nil,
            uptime: s.uptime()
        )
    }

    private func publish(_ new: SystemSnapshot) {
        var merged = new
        // Slow metrics are sampled less often: carry the last value forward between samples.
        if merged.battery == nil { merged.battery = snapshot.battery }
        if merged.storage == nil { merged.storage = snapshot.storage }
        // First CPU / network sample has no delta yet: keep the previous reading rather than showing nothing.
        if merged.cpu == nil { merged.cpu = snapshot.cpu }
        if merged.network == nil { merged.network = snapshot.network }
        snapshot = merged

        let t = merged.timestamp
        if let c = new.cpu { cpuRing.append(MetricPoint(time: t, value: c.total)); cpuHistory = cpuRing.elements }
        if let m = new.memory { memRing.append(MetricPoint(time: t, value: m.usedFraction)); memoryHistory = memRing.elements }
        if let n = new.network {
            downRing.append(MetricPoint(time: t, value: n.downBytesPerSecond)); downHistory = downRing.elements
            upRing.append(MetricPoint(time: t, value: n.upBytesPerSecond)); upHistory = upRing.elements
        }
    }
}
