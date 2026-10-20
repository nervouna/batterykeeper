import Foundation

/// The helper's rule for cutting the adapter: only under a lease that the app keeps renewing, and never at or
/// below a hard floor. Anything unknown (no lease, an expired one, an unreadable charge) means the adapter is on.
public struct AdapterLease: Sendable, Equatable {
    /// The longest lease the helper grants.
    public static let maximumDuration: TimeInterval = 120
    /// At or below this charge the adapter is restored whatever the lease says, percent.
    public static let hardFloorPercent = 10

    /// When the current lease ends; nil without one.
    public private(set) var expiresAt: Date?

    public init() {}

    /// Asks for the adapter to be cut for `duration` seconds (clamped to ``maximumDuration``), or, with
    /// `enabled` true, ends the lease. A duration of zero or less ends it too.
    public mutating func request(enabled: Bool, duration: TimeInterval, now: Date) {
        if enabled || duration <= 0 {
            expiresAt = nil
        } else {
            expiresAt = now.addingTimeInterval(min(duration, Self.maximumDuration))
        }
    }

    public mutating func release() {
        expiresAt = nil
    }

    /// Whether the adapter should power the Mac.
    public func adapterEnabled(now: Date, percent: Int?) -> Bool {
        guard let expiresAt, now < expiresAt else { return true }
        guard let percent, percent > Self.hardFloorPercent else { return true }
        return false
    }

    /// Seconds left on the lease, zero without one.
    public func remaining(now: Date) -> TimeInterval {
        guard let expiresAt else { return 0 }
        return max(0, expiresAt.timeIntervalSince(now))
    }
}
