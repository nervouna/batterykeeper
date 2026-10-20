import Foundation

/// What the battery is doing, as the menu bar and the popover describe it.
public enum BatteryStatus: String, Sendable, Equatable, CaseIterable {
    /// No adapter.
    case onBattery
    case charging
    /// On power, not charging, below 100 %: the charge limit holds it.
    case heldAtLimit
    /// On power at 100 %.
    case full
    /// On power but the battery discharges: the adapter is cut for a calibration cycle, or the system
    /// draws more than the adapter supplies.
    case dischargingOnPower

    /// Discharge currents smaller than this (amperes) count as idle.
    static let idleCurrent = 0.05

    public init(_ snapshot: BatterySnapshot) {
        if !snapshot.isPluggedIn {
            self = .onBattery
        } else if snapshot.isCharging {
            self = .charging
        } else if snapshot.amperage < -Self.idleCurrent {
            self = .dischargingOnPower
        } else if snapshot.percent >= 100 || snapshot.isFullyCharged {
            self = .full
        } else {
            self = .heldAtLimit
        }
    }
}
