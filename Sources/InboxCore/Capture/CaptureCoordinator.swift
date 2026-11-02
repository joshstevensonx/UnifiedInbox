import Foundation

/// Runs every capture source on its own interval and writes results into the store.
public actor CaptureCoordinator {
    private let store: InboxStore
    private var sources: [CaptureSource] = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private var statuses: [String: CaptureStatus] = [:]
    private var rules = AlertRules()
    private var ruleSet = RuleSet()
    private var enabledPlatforms: Set<Platform> = Platform.defaultEnabled

    /// Called with genuinely new items (e.g. to update the menu-bar badge).
    private let onNewItems: @Sendable ([InboxItem]) -> Void

    public init(store: InboxStore,
                enabledPlatforms: Set<Platform> = Platform.defaultEnabled,
                rules: AlertRules = AlertRules(),
                onNewItems: @escaping @Sendable ([InboxItem]) -> Void = { _ in }) {
        self.store = store
        self.enabledPlatforms = enabledPlatforms
        self.rules = rules
        self.onNewItems = onNewItems
    }

    public func setRules(_ rules: AlertRules) {
        self.rules = rules
    }

    public func setRuleSet(_ ruleSet: RuleSet) {
        self.ruleSet = ruleSet
    }

    /// Turning a platform on rescans the Notification Center DB so its existing notifications are imported.
    public func setEnabledPlatforms(_ platforms: Set<Platform>) {
        let added = platforms.subtracting(enabledPlatforms)
        enabledPlatforms = platforms
        if !added.isEmpty { try? store.setValue("0", for: NotificationCenterSource.cursorKey) }
        rebalancePlatforms()
    }

    public func add(_ source: CaptureSource) {
        sources.removeAll { $0.identifier == source.identifier }
        sources.append(source)
        rebalancePlatforms()
    }

    public func remove(identifier: String) {
        tasks[identifier]?.cancel()
        tasks[identifier] = nil
        sources.removeAll { $0.identifier == identifier }
        rebalancePlatforms()
    }

    public func status(of identifier: String) -> CaptureStatus {
        statuses[identifier] ?? .idle
    }

    public func start() {
        for source in sources where tasks[source.identifier] == nil {
            tasks[source.identifier] = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.runOnce(source)
                    try? await Task.sleep(nanoseconds: UInt64(source.pollInterval * 1_000_000_000))
                }
            }
        }
    }

    public func stop() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }

    /// Poll one source immediately (also used by "Refresh").
    public func runOnce(_ source: CaptureSource) async {
        do {
            let items = try await source.poll(store: store)
            let new = try store.insertNew(items.filter { enabledPlatforms.contains($0.platform) }, rules: rules, ruleSet: ruleSet)
            statuses[source.identifier] = .running
            if !new.isEmpty { onNewItems(new) }
        } catch {
            statuses[source.identifier] = .failed(error.localizedDescription)
        }
    }

    public func refreshAll() async {
        for s in sources { await runOnce(s) }
    }

    /// Platforms covered by Graph are removed from Notification Center capture to avoid duplicates.
    private func rebalancePlatforms() {
        let graphPlatforms = sources.first { $0.identifier == "graph" }?.platforms ?? []
        if let nc = sources.first(where: { $0 is NotificationCenterSource }) as? NotificationCenterSource {
            nc.setPlatforms(enabledPlatforms.subtracting(graphPlatforms))
        }
    }
}
