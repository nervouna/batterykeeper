import BatteryKeeperCore
import Foundation
import Testing

@testable import BatteryKeeperHelperKit

/// Records every write and can be told to fail.
final class FakeAdapter: AdapterSwitch, @unchecked Sendable {
    private let lock = NSLock()
    private var _enabled = true
    private var _writes: [Bool] = []
    var failCut = false

    var enabled: Bool { lock.withLock { _enabled } }
    var writes: [Bool] { lock.withLock { _writes } }

    func setAdapterEnabled(_ enabled: Bool) throws {
        if !enabled && failCut { throw UnavailableAdapterSwitch.Unavailable() }
        lock.withLock {
            _enabled = enabled
            _writes.append(enabled)
        }
    }

    func isAdapterEnabled() throws -> Bool { enabled }

    /// Something other than the helper restores the adapter.
    func externallyEnable() { lock.withLock { _enabled = true } }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = Date(timeIntervalSince1970: 1_800_000_000)
    private var _percent: Int? = 80
    var now: Date { lock.withLock { _now } }
    var percent: Int? {
        get { lock.withLock { _percent } }
        set { lock.withLock { _percent = newValue } }
    }
    func advance(_ seconds: TimeInterval) { lock.withLock { _now = _now.addingTimeInterval(seconds) } }
}

@Suite struct HelperServiceTests {
    let adapter = FakeAdapter()
    let clock = Clock()
    let owner = UUID()

    func makeService() -> HelperService {
        let clock = self.clock
        let service = HelperService(adapter: adapter, percent: { clock.percent }, now: { clock.now })
        service.start(checking: false)
        return service
    }

    @Test func startRestoresTheAdapter() {
        _ = makeService()
        #expect(adapter.writes == [true])
    }

    @Test func leaseCutsAndExpiryRestores() {
        let service = makeService()
        #expect(service.request(enabled: false, leaseSeconds: 90, owner: owner) == nil)
        #expect(!adapter.enabled)
        clock.advance(60)
        service.enforceNow()
        #expect(!adapter.enabled)
        clock.advance(31)
        service.enforceNow()
        #expect(adapter.enabled)
        #expect(service.state().leaseRemaining == 0)
    }

    @Test func renewingExtendsTheLease() {
        let service = makeService()
        _ = service.request(enabled: false, leaseSeconds: 90, owner: owner)
        clock.advance(60)
        _ = service.request(enabled: false, leaseSeconds: 90, owner: owner)
        clock.advance(60)
        service.enforceNow()
        #expect(!adapter.enabled)
    }

    @Test func hardFloorRestores() {
        let service = makeService()
        _ = service.request(enabled: false, leaseSeconds: 90, owner: owner)
        clock.percent = AdapterLease.hardFloorPercent
        service.enforceNow()
        #expect(adapter.enabled)
    }

    @Test func refusesAtTheFloorOrWithAnUnreadableCharge() {
        let service = makeService()
        clock.percent = nil
        #expect(service.request(enabled: false, leaseSeconds: 90, owner: owner) != nil)
        #expect(adapter.enabled)
    }

    @Test func connectionEndRestoresOnlyForTheOwner() {
        let service = makeService()
        _ = service.request(enabled: false, leaseSeconds: 90, owner: owner)
        service.connectionEnded(owner: UUID())
        #expect(!adapter.enabled)
        service.connectionEnded(owner: owner)
        #expect(adapter.enabled)
    }

    @Test func sleepAndShutdownRestore() {
        let service = makeService()
        _ = service.request(enabled: false, leaseSeconds: 90, owner: owner)
        service.prepareForSleep()
        #expect(adapter.enabled)
        _ = service.request(enabled: false, leaseSeconds: 90, owner: owner)
        service.shutdown()
        #expect(adapter.enabled)
    }

    @Test func failedCutIsReportedAndLeavesNoLease() {
        adapter.failCut = true
        let service = makeService()
        #expect(service.request(enabled: false, leaseSeconds: 90, owner: owner) != nil)
        #expect(service.state().leaseRemaining == 0)
        #expect(adapter.enabled)
    }

    @Test func externalRestoreDuringALeaseIsUndone() {
        let service = makeService()
        _ = service.request(enabled: false, leaseSeconds: 90, owner: owner)
        adapter.externallyEnable()
        service.enforceNow()
        #expect(!adapter.enabled)
    }

    @Test func idleChecksDoNotWrite() {
        let service = makeService()
        service.enforceNow()
        service.enforceNow()
        #expect(adapter.writes == [true])
    }
}
