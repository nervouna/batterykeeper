import BatteryKeeperCore
import BatteryKeeperSystem
import Foundation
import os

/// The helper's state: the adapter lease and who holds it. Every change goes through one serial queue, and
/// every path that ends a lease (expiry, the hard floor, the connection ending, sleep, termination) restores
/// the adapter.
public final class HelperService: @unchecked Sendable {
    /// How often the lease and the floor are checked.
    public static let checkInterval: TimeInterval = 5

    private let queue = DispatchQueue(label: "io.damao.batterykeeper.helper.service")
    private let adapter: any AdapterSwitch
    private let percent: @Sendable () -> Int?
    private let now: @Sendable () -> Date
    private let log = Logger(subsystem: "io.damao.batterykeeper.helper", category: "service")

    private var lease = AdapterLease()
    private var leaseOwner: UUID?
    /// This helper cut the adapter and owes a restore.
    private var isCut = false
    private var timer: DispatchSourceTimer?

    public init(
        adapter: any AdapterSwitch, percent: @escaping @Sendable () -> Int?, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.adapter = adapter
        self.percent = percent
        self.now = now
    }

    /// Restores the adapter (whatever an earlier run left behind) and starts the periodic check.
    public func start(checking: Bool = true) {
        queue.sync {
            restore(reason: "start", force: true)
            guard checking else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.checkInterval, repeating: Self.checkInterval)
            timer.setEventHandler { [weak self] in self?.enforce() }
            timer.resume()
            self.timer = timer
        }
    }

    /// Handles a request from a client connection.
    public func request(enabled: Bool, leaseSeconds: Double, owner: UUID) -> (any Error)? {
        queue.sync {
            lease.request(enabled: enabled, duration: leaseSeconds, now: now())
            leaseOwner = enabled ? nil : owner
            if enabled {
                restore(reason: "requested", force: false)
                return nil
            }
            guard !lease.adapterEnabled(now: now(), percent: percent()) else {
                lease.release()
                leaseOwner = nil
                return HelperRefusal(description: "the charge is at or below the hard floor, or unreadable")
            }
            do {
                try adapter.setAdapterEnabled(false)
                if !isCut { log.notice("adapter cut") }
                isCut = true
                return nil
            } catch {
                log.error("cutting the adapter failed: \(String(describing: error), privacy: .public)")
                lease.release()
                leaseOwner = nil
                return error
            }
        }
    }

    /// The adapter is on, and the seconds left on the lease.
    public func state() -> (enabled: Bool, leaseRemaining: Double) {
        queue.sync {
            let enabled = (try? adapter.isAdapterEnabled()) ?? !isCut
            return (enabled, lease.remaining(now: now()))
        }
    }

    /// A client connection ended: if it held the lease, the lease ends with it.
    public func connectionEnded(owner: UUID) {
        queue.sync {
            guard leaseOwner == owner else { return }
            lease.release()
            leaseOwner = nil
            restore(reason: "client went away", force: false)
        }
    }

    public func prepareForSleep() {
        queue.sync {
            lease.release()
            leaseOwner = nil
            restore(reason: "system sleep", force: false)
        }
    }

    /// Restores the adapter before the process exits.
    public func shutdown() {
        queue.sync {
            timer?.cancel()
            timer = nil
            lease.release()
            leaseOwner = nil
            restore(reason: "shutdown", force: true)
        }
    }

    /// The periodic check. Internal so that tests can run it without waiting for the timer.
    func enforce() {
        dispatchPrecondition(condition: .onQueue(queue))
        if lease.adapterEnabled(now: now(), percent: percent()) {
            if lease.expiresAt != nil {
                log.notice("lease ended by the hard floor or an unreadable charge")
            }
            lease.release()
            leaseOwner = nil
            restore(reason: "lease over", force: false)
        } else if isCut, (try? adapter.isAdapterEnabled()) == true {
            // Something else restored it while the lease runs: cut it again.
            try? adapter.setAdapterEnabled(false)
        }
    }

    func enforceNow() {
        queue.sync { enforce() }
    }

    /// Restores the adapter if this helper cut it, or always with `force`. A failed restore keeps `isCut`
    /// set, so the next check tries again.
    private func restore(reason: String, force: Bool) {
        guard isCut || force else { return }
        do {
            try adapter.setAdapterEnabled(true)
            if isCut { log.notice("adapter restored: \(reason, privacy: .public)") }
            isCut = false
        } catch {
            log.error("restoring the adapter failed (\(reason, privacy: .public)): \(String(describing: error), privacy: .public)")
        }
    }
}

struct HelperRefusal: Error, CustomStringConvertible {
    var description: String
}
