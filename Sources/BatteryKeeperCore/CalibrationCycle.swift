import Foundation

/// The phases of a calibration cycle, in order.
public enum CyclePhase: String, Codable, Sendable, CaseIterable {
    /// Charge to 100 % with the charge limit lifted.
    case chargeToFull
    /// Cut the adapter and discharge to the floor.
    case dischargeToFloor
    /// Charge to 100 % again.
    case rechargeToFull
    /// Stay at 100 % on power for the hold time.
    case holdFull
    /// Cut the adapter and discharge to the daily limit.
    case dischargeToLimit

    /// 1-based position, for "phase 2 of 5".
    public var number: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }
}

/// How scheduled cycles run.
public struct CycleSettings: Codable, Sendable, Equatable {
    /// Start cycles on the schedule (a cycle can always be started by hand).
    public var isScheduled: Bool
    /// Days between the end of one cycle and the start of the next.
    public var intervalDays: Int
    /// Hour of the day (0–23, local time) from which a due cycle may start.
    public var startHour: Int
    /// Charge to discharge to, percent.
    public var floorPercent: Int
    /// Minutes to stay at 100 % before discharging to the limit.
    public var holdMinutes: Int

    public static let intervalRange = 7...90
    public static let floorRange = 15...50
    public static let holdRange = 0...240

    public static let `default` = CycleSettings(
        isScheduled: true, intervalDays: 28, startHour: 20, floorPercent: 15, holdMinutes: 60)

    public init(isScheduled: Bool, intervalDays: Int, startHour: Int, floorPercent: Int, holdMinutes: Int) {
        self.isScheduled = isScheduled
        self.intervalDays = intervalDays
        self.startHour = startHour
        self.floorPercent = floorPercent
        self.holdMinutes = holdMinutes
    }

    /// The settings with every value moved into its allowed range.
    public func clamped() -> CycleSettings {
        CycleSettings(
            isScheduled: isScheduled,
            intervalDays: intervalDays.clamped(to: Self.intervalRange),
            startHour: startHour.clamped(to: 0...23),
            floorPercent: floorPercent.clamped(to: Self.floorRange),
            holdMinutes: holdMinutes.clamped(to: Self.holdRange))
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.default
        self.init(
            isScheduled: try c.decodeIfPresent(Bool.self, forKey: .isScheduled) ?? d.isScheduled,
            intervalDays: try c.decodeIfPresent(Int.self, forKey: .intervalDays) ?? d.intervalDays,
            startHour: try c.decodeIfPresent(Int.self, forKey: .startHour) ?? d.startHour,
            floorPercent: try c.decodeIfPresent(Int.self, forKey: .floorPercent) ?? d.floorPercent,
            holdMinutes: try c.decodeIfPresent(Int.self, forKey: .holdMinutes) ?? d.holdMinutes)
        self = clamped()
    }
}

/// A running calibration cycle. Persisted, so that a relaunch resumes it.
public struct CycleState: Codable, Sendable, Equatable {
    public var phase: CyclePhase
    public var startedAt: Date
    public var phaseStartedAt: Date
    /// The daily limit to restore when the cycle ends, percent; 100 means no limit.
    public var restoreLimit: Int
    public var floorPercent: Int
    public var holdMinutes: Int
    public var isManual: Bool
    /// The charge that counts as full, percent. Always 100, except in shortened test cycles.
    public var fullPercent: Int

    public init(
        phase: CyclePhase, startedAt: Date, phaseStartedAt: Date, restoreLimit: Int, floorPercent: Int,
        holdMinutes: Int, isManual: Bool, fullPercent: Int = 100
    ) {
        self.phase = phase
        self.startedAt = startedAt
        self.phaseStartedAt = phaseStartedAt
        self.restoreLimit = restoreLimit
        self.floorPercent = floorPercent
        self.holdMinutes = holdMinutes
        self.isManual = isManual
        self.fullPercent = fullPercent
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            phase: try c.decode(CyclePhase.self, forKey: .phase),
            startedAt: try c.decode(Date.self, forKey: .startedAt),
            phaseStartedAt: try c.decode(Date.self, forKey: .phaseStartedAt),
            restoreLimit: try c.decode(Int.self, forKey: .restoreLimit),
            floorPercent: try c.decode(Int.self, forKey: .floorPercent),
            holdMinutes: try c.decode(Int.self, forKey: .holdMinutes),
            isManual: try c.decode(Bool.self, forKey: .isManual),
            fullPercent: try c.decodeIfPresent(Int.self, forKey: .fullPercent) ?? 100)
    }

    /// The charge the current phase is heading for, nil while holding.
    public var targetPercent: Int? {
        switch phase {
        case .chargeToFull, .rechargeToFull: fullPercent
        case .dischargeToFloor: floorPercent
        case .holdFull: nil
        case .dischargeToLimit: restoreLimit
        }
    }

    /// When the hold ends, while holding.
    public var holdEndsAt: Date? {
        phase == .holdFull ? phaseStartedAt.addingTimeInterval(TimeInterval(holdMinutes) * 60) : nil
    }
}

/// What a cycle phase needs from the system.
public struct CycleDirective: Equatable, Sendable {
    /// Whether the adapter powers the Mac; false asks the helper to cut it.
    public var adapterEnabled: Bool
    /// Whether to keep the Mac from sleeping while idle.
    public var preventSleep: Bool

    public init(adapterEnabled: Bool, preventSleep: Bool) {
        self.adapterEnabled = adapterEnabled
        self.preventSleep = preventSleep
    }
}

public enum CycleOutcome: Equatable, Sendable {
    /// Still running, in the given state (its phase may have changed).
    case running(CycleState)
    /// Every phase is done.
    case finished
    /// It ran longer than ``CalibrationCycle/maximumDuration`` and is given up.
    case expired
}

/// The rules of a calibration cycle: charge to 100 %, discharge to the floor, charge to 100 %, hold, then
/// discharge to the daily limit. Every transition is a function of the state, a snapshot and the time.
public enum CalibrationCycle {
    /// A cycle still running after this long is given up (sleep pauses a cycle but not this clock).
    public static let maximumDuration: TimeInterval = 72 * 3600

    public static func start(at now: Date, restoreLimit: Int, settings: CycleSettings, manual: Bool) -> CycleState {
        let settings = settings.clamped()
        return CycleState(
            phase: .chargeToFull,
            startedAt: now,
            phaseStartedAt: now,
            restoreLimit: restoreLimit.clamped(to: 0...100),
            floorPercent: settings.floorPercent,
            holdMinutes: settings.holdMinutes,
            isManual: manual)
    }

    /// Advances through every phase whose goal the snapshot already meets.
    public static func advance(_ state: CycleState, snapshot: BatterySnapshot, now: Date) -> CycleOutcome {
        if now.timeIntervalSince(state.startedAt) > maximumDuration {
            return .expired
        }
        var state = state
        // Five phases at most, so this loop runs at most six times.
        while true {
            let next: CyclePhase?
            switch state.phase {
            case .chargeToFull:
                guard snapshot.percent >= state.fullPercent else { return .running(state) }
                next = .dischargeToFloor
            case .dischargeToFloor:
                guard snapshot.percent <= state.floorPercent else { return .running(state) }
                next = .rechargeToFull
            case .rechargeToFull:
                guard snapshot.percent >= state.fullPercent else { return .running(state) }
                next = .holdFull
            case .holdFull:
                guard let end = state.holdEndsAt, now >= end else { return .running(state) }
                next = .dischargeToLimit
            case .dischargeToLimit:
                guard snapshot.percent <= state.restoreLimit else { return .running(state) }
                next = nil
            }
            guard let next else { return .finished }
            state.phase = next
            state.phaseStartedAt = now
        }
    }

    public static func directive(for phase: CyclePhase) -> CycleDirective {
        switch phase {
        case .chargeToFull, .rechargeToFull, .holdFull:
            CycleDirective(adapterEnabled: true, preventSleep: false)
        case .dischargeToFloor, .dischargeToLimit:
            CycleDirective(adapterEnabled: false, preventSleep: true)
        }
    }
}

/// When scheduled cycles start.
public enum CycleSchedule {
    /// The first moment the next cycle may start: `intervalDays` after the day of `reference` (the end of the
    /// last cycle, or when scheduling began), at `startHour`.
    public static func nextStart(after reference: Date, settings: CycleSettings, calendar: Calendar) -> Date {
        let settings = settings.clamped()
        let day = calendar.startOfDay(for: reference)
        let dueDay = calendar.date(byAdding: .day, value: settings.intervalDays, to: day) ?? day
        return calendar.date(bySettingHour: settings.startHour, minute: 0, second: 0, of: dueDay) ?? dueDay
    }

    /// Whether a scheduled cycle starts now: it is due and the Mac is on power. A cycle that fell due while
    /// the Mac was asleep or unplugged starts at the first opportunity after.
    public static func shouldStart(
        now: Date, reference: Date, settings: CycleSettings, snapshot: BatterySnapshot, calendar: Calendar
    ) -> Bool {
        settings.isScheduled && snapshot.isPluggedIn
            && now >= nextStart(after: reference, settings: settings, calendar: calendar)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
