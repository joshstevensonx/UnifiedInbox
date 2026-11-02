import Foundation
import XCTest
@testable import NexusCore

final class ThresholdTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func snap(cpu: Double? = nil, pressure: MemoryPressure? = nil, battery: BatteryState? = nil,
                      freeBytes: Int64? = nil) -> SystemSnapshot {
        SystemSnapshot(
            cpu: cpu.map { CPUReading(total: $0, user: $0, system: 0) },
            memory: pressure.map { MemoryReading(totalBytes: 16, usedBytes: 8, wiredBytes: 0, compressedBytes: 0, pressure: $0) },
            battery: battery,
            storage: freeBytes.map { StorageReading(totalBytes: 500_000_000_000, availableBytes: $0) }
        )
    }

    private func settings(_ kinds: Set<ThresholdKind>) -> ThresholdSettings {
        var s = ThresholdSettings()
        s.enabled = kinds
        s.cpuSustainSeconds = 60
        s.cooldownMinutes = 30
        return s
    }

    func testCPUMustBeSustainedAndFiresOncePerBreach() {
        var e = ThresholdEvaluator()
        let s = settings([.cpu])
        XCTAssertTrue(e.evaluate(snap(cpu: 0.95), settings: s, now: t0).isEmpty)
        XCTAssertTrue(e.evaluate(snap(cpu: 0.95), settings: s, now: t0 + 30).isEmpty)  // not sustained yet
        let fired = e.evaluate(snap(cpu: 0.95), settings: s, now: t0 + 60)
        XCTAssertEqual(fired.map(\.kind), [.cpu])
        // Still breached: no repeat alert for the same continuous breach.
        XCTAssertTrue(e.evaluate(snap(cpu: 0.99), settings: s, now: t0 + 120).isEmpty)
        XCTAssertTrue(e.evaluate(snap(cpu: 0.99), settings: s, now: t0 + 4_000).isEmpty)
    }

    func testDipResetsSustainTimer() {
        var e = ThresholdEvaluator()
        let s = settings([.cpu])
        _ = e.evaluate(snap(cpu: 0.95), settings: s, now: t0)
        _ = e.evaluate(snap(cpu: 0.20), settings: s, now: t0 + 40)   // clears
        XCTAssertTrue(e.evaluate(snap(cpu: 0.95), settings: s, now: t0 + 70).isEmpty)
        XCTAssertEqual(e.evaluate(snap(cpu: 0.95), settings: s, now: t0 + 130).count, 1)
    }

    func testCooldownAfterClearing() {
        var e = ThresholdEvaluator()
        let s = settings([.disk])
        XCTAssertEqual(e.evaluate(snap(freeBytes: 1_000), settings: s, now: t0).count, 1)
        _ = e.evaluate(snap(freeBytes: 50_000_000_000), settings: s, now: t0 + 60)       // cleared
        XCTAssertTrue(e.evaluate(snap(freeBytes: 1_000), settings: s, now: t0 + 120).isEmpty) // within 30 min cooldown
        // Breach continues; once the cooldown has passed it may fire again (it cleared before).
        XCTAssertEqual(e.evaluate(snap(freeBytes: 1_000), settings: s, now: t0 + 1_900).count, 1)
    }

    func testUnavailableMetricChangesNothing() {
        var e = ThresholdEvaluator()
        let s = settings([.cpu])
        _ = e.evaluate(snap(cpu: 0.95), settings: s, now: t0)
        // Missing CPU reading must neither fire nor reset the sustain timer.
        XCTAssertTrue(e.evaluate(snap(), settings: s, now: t0 + 30).isEmpty)
        XCTAssertEqual(e.evaluate(snap(cpu: 0.95), settings: s, now: t0 + 61).count, 1)
        // Unknown memory pressure is "unavailable" too.
        var m = ThresholdEvaluator()
        XCTAssertTrue(m.evaluate(snap(pressure: .unknown), settings: settings([.memory]), now: t0 + 999).isEmpty)
    }

    func testDisabledKindsNeverFire() {
        var e = ThresholdEvaluator()
        XCTAssertTrue(e.evaluate(snap(cpu: 1, freeBytes: 0), settings: settings([]), now: t0).isEmpty)
        XCTAssertTrue(e.evaluate(snap(cpu: 1, freeBytes: 0), settings: settings([]), now: t0 + 9_999).isEmpty)
    }

    func testBatteryIgnoresACPowerAndNoBattery() {
        var e = ThresholdEvaluator()
        let s = settings([.battery])
        let low = BatteryReading(level: 0.10, isCharging: false, onACPower: false, minutesRemaining: 20)
        var charging = low; charging.onACPower = true; charging.isCharging = true
        XCTAssertTrue(e.evaluate(snap(battery: .noBattery), settings: s, now: t0).isEmpty)
        XCTAssertTrue(e.evaluate(snap(battery: .reading(charging)), settings: s, now: t0).isEmpty)
        let fired = e.evaluate(snap(battery: .reading(low)), settings: s, now: t0 + 1)
        XCTAssertEqual(fired.map(\.kind), [.battery])
        XCTAssertTrue(fired[0].message.contains("10%"))
    }

    func testMemoryCriticalOnly() {
        var e = ThresholdEvaluator()
        var s = settings([.memory])
        s.memorySustainSeconds = 0
        s.memoryCriticalOnly = true
        XCTAssertTrue(e.evaluate(snap(pressure: .warning), settings: s, now: t0).isEmpty)
        XCTAssertEqual(e.evaluate(snap(pressure: .critical), settings: s, now: t0 + 1).count, 1)
    }

    func testSettingsCodable() throws {
        var s = ThresholdSettings()
        s.enabled = [.cpu, .disk]
        s.batteryLimit = 0.2
        let back = try JSONDecoder().decode(ThresholdSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }

    func testSampledHistoryThinsAndCaps() throws {
        var h = SampledHistory(capacity: 3, minInterval: 300)
        XCTAssertTrue(h.record(1, at: t0))
        XCTAssertFalse(h.record(2, at: t0 + 100))     // too soon
        XCTAssertTrue(h.record(3, at: t0 + 300))
        XCTAssertTrue(h.record(4, at: t0 + 600))
        XCTAssertTrue(h.record(5, at: t0 + 900))
        XCTAssertEqual(h.points.map(\.value), [3, 4, 5])
        let back = try JSONDecoder().decode(SampledHistory.self, from: JSONEncoder().encode(h))
        XCTAssertEqual(back, h)
    }
}
