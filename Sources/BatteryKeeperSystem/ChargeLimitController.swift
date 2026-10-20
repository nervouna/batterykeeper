import BatteryKeeperBridge
import Foundation

/// The system charge limit as BatteryKeeper sees it.
public struct ChargeLimitState: Sendable, Equatable {
    /// The private API is available and the Mac supports a manual charge limit.
    public var isSupported: Bool
    /// The limit in force, percent: 100 when the limit is off.
    public var limit: Int
    /// The limits System Settings offers.
    public var available: [Int]

    public static let unsupported = ChargeLimitState(isSupported: false, limit: 100, available: [])
}

public struct ChargeLimitError: Error, CustomStringConvertible, Sendable {
    public var description: String
}

/// Reads and sets the system charge limit ("Charge Limit" in System Settings, enforced by powerd) through
/// the private PowerUI framework. A limit of 100 % means the limit is off.
@MainActor
public final class ChargeLimitController {
    /// Offered when the system does not list its limits.
    static let fallbackLimits = [80, 85, 90, 95, 100]

    private let client: BKPowerUI?

    public init() {
        client = BKPowerUI.sharedClient()
    }

    public func read() -> ChargeLimitState {
        guard let client, client.supportsManualChargeLimit else { return .unsupported }
        let available = ((try? client.availableLimits()) ?? []).map(\.intValue).filter { (1...100).contains($0) }
        let enabled = ((try? client.enabledState())?.intValue ?? 0) != 0
        var limit = 100
        if enabled, let stored = try? client.limit().intValue, (1..<100).contains(stored) {
            limit = Self.displayLimit(stored: stored, available: available)
        }
        return ChargeLimitState(
            isSupported: true, limit: limit, available: available.isEmpty ? Self.fallbackLimits : available)
    }

    /// Sets the limit, 100 switching it off.
    ///
    /// Setting a limit also switches it on. `enableMCL` must not follow: it resets the limit to the
    /// system's default (80). It is only used when the limit is still off after setting it, and the
    /// limit is set again after it.
    public func setLimit(_ limit: Int) throws(ChargeLimitError) {
        guard let client else { throw ChargeLimitError(description: "PowerUI is not available") }
        do {
            if limit >= 100 {
                try client.disable()
                return
            }
            try client.setLimit(limit)
            if (try client.enabledState().intValue) == 0 {
                try client.enable()
                try client.setLimit(limit)
            }
        } catch {
            throw ChargeLimitError(description: error.localizedDescription)
        }
    }

    /// Switches the limit off, for a calibration cycle.
    public func disable() throws(ChargeLimitError) {
        try setLimit(100)
    }

    /// "Charge to Full Now".
    public func chargeToFullNow() throws(ChargeLimitError) {
        guard let client else { throw ChargeLimitError(description: "PowerUI is not available") }
        do {
            try client.temporarilyDisable()
        } catch {
            throw ChargeLimitError(description: error.localizedDescription)
        }
    }

    /// The system may store a limit one below the value offered (79 for 80); show the offered value then.
    static func displayLimit(stored: Int, available: [Int]) -> Int {
        if available.contains(stored) { return stored }
        if available.contains(stored + 1) { return stored + 1 }
        return stored
    }
}
