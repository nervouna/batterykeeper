import Foundation

public enum BatteryEventKind: String, Codable, Sendable, CaseIterable {
    case appLaunched
    case pluggedIn
    case unplugged
    case chargingStarted
    case chargingStopped
    case fullyCharged
    /// The daily limit changed; the detail is the new limit in percent ("100" for none).
    case limitChanged
    case chargeToFullNow
    /// The detail is "manual" or "scheduled".
    case cycleStarted
    /// The detail is the new phase's raw value.
    case cyclePhase
    case cycleFinished
    case cycleCancelled
    case cycleExpired
    /// The detail is the error message.
    case helperProblem
}

/// Something worth a line in the event log. The detail is data (a number, a phase), not prose, so that the
/// interface can word it in its own language.
public struct BatteryEvent: Sendable, Equatable {
    public var date: Date
    public var kind: BatteryEventKind
    public var detail: String

    public init(date: Date, kind: BatteryEventKind, detail: String = "") {
        self.date = date
        self.kind = kind
        self.detail = detail
    }
}

/// Finds the events between two consecutive snapshots.
public enum EventDetector {
    public static func events(from old: BatterySnapshot?, to new: BatterySnapshot) -> [BatteryEvent] {
        guard let old else { return [] }
        var events: [BatteryEvent] = []
        if old.isPluggedIn != new.isPluggedIn {
            events.append(BatteryEvent(date: new.date, kind: new.isPluggedIn ? .pluggedIn : .unplugged, detail: "\(new.percent)"))
        }
        if old.isCharging != new.isCharging {
            events.append(
                BatteryEvent(date: new.date, kind: new.isCharging ? .chargingStarted : .chargingStopped, detail: "\(new.percent)"))
        }
        if new.isPluggedIn && old.percent < 100 && new.percent >= 100 {
            events.append(BatteryEvent(date: new.date, kind: .fullyCharged))
        }
        return events
    }
}
