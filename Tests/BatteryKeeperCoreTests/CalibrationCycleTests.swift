import BatteryKeeperCore
import Foundation
import Testing

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func snapshot(_ percent: Int, pluggedIn: Bool = true, at date: Date = t0) -> BatterySnapshot {
    BatterySnapshot(date: date, percent: percent, isPluggedIn: pluggedIn, isCharging: false)
}

private func started(limit: Int = 80, floor: Int = 15, hold: Int = 60) -> CycleState {
    var settings = CycleSettings.default
    settings.floorPercent = floor
    settings.holdMinutes = hold
    return CalibrationCycle.start(at: t0, restoreLimit: limit, settings: settings, manual: true)
}

@Suite struct CalibrationCycleTests {
    @Test func startsByChargingToFull() {
        let state = started()
        #expect(state.phase == .chargeToFull)
        #expect(state.targetPercent == 100)
        #expect(CalibrationCycle.directive(for: .chargeToFull) == CycleDirective(adapterEnabled: true, preventSleep: false))
    }

    @Test func staysUntilTheGoalIsMet() {
        let outcome = CalibrationCycle.advance(started(), snapshot: snapshot(99), now: t0.addingTimeInterval(60))
        #expect(outcome == .running(started()))
    }

    @Test func runsThroughEveryPhase() {
        var state = started(hold: 60)
        var now = t0

        func step(_ percent: Int, after seconds: TimeInterval) -> CycleOutcome {
            now = now.addingTimeInterval(seconds)
            return CalibrationCycle.advance(state, snapshot: snapshot(percent, at: now), now: now)
        }

        guard case .running(let s1) = step(100, after: 3600) else { Issue.record("expected running"); return }
        #expect(s1.phase == .dischargeToFloor)
        #expect(s1.phaseStartedAt == now)
        #expect(s1.targetPercent == 15)
        #expect(CalibrationCycle.directive(for: s1.phase) == CycleDirective(adapterEnabled: false, preventSleep: true))
        state = s1

        guard case .running(let s2) = step(15, after: 3600 * 8) else { Issue.record("expected running"); return }
        #expect(s2.phase == .rechargeToFull)
        state = s2

        guard case .running(let s3) = step(100, after: 3600 * 2) else { Issue.record("expected running"); return }
        #expect(s3.phase == .holdFull)
        #expect(s3.holdEndsAt == now.addingTimeInterval(3600))
        state = s3

        guard case .running(let s4) = step(100, after: 1800) else { Issue.record("expected running"); return }
        #expect(s4.phase == .holdFull)
        state = s4

        guard case .running(let s5) = step(100, after: 1800) else { Issue.record("expected running"); return }
        #expect(s5.phase == .dischargeToLimit)
        #expect(s5.targetPercent == 80)
        state = s5

        #expect(step(81, after: 600) == .running(s5))
        #expect(step(80, after: 600) == .finished)
    }

    @Test func skipsPhasesAlreadyDone() {
        // Already full at the start: straight to discharging.
        guard case .running(let s) = CalibrationCycle.advance(started(), snapshot: snapshot(100), now: t0) else {
            Issue.record("expected running")
            return
        }
        #expect(s.phase == .dischargeToFloor)
    }

    @Test func zeroHoldAndNoLimitFinishAtFull() {
        var state = started(limit: 100, hold: 0)
        state.phase = .rechargeToFull
        #expect(CalibrationCycle.advance(state, snapshot: snapshot(100), now: t0) == .finished)
    }

    @Test func expiresAfterTheMaximumDuration() {
        let late = t0.addingTimeInterval(CalibrationCycle.maximumDuration + 1)
        #expect(CalibrationCycle.advance(started(), snapshot: snapshot(50), now: late) == .expired)
    }

    @Test func settingsAreClamped() {
        let settings = CycleSettings(isScheduled: true, intervalDays: 1, startHour: 30, floorPercent: 5, holdMinutes: 999)
            .clamped()
        #expect(settings.intervalDays == 7)
        #expect(settings.startHour == 23)
        #expect(settings.floorPercent == 15)
        #expect(settings.holdMinutes == 240)
    }

    @Test func shortenedCycleCountsALowerChargeAsFull() {
        var state = started(limit: 80, floor: 77, hold: 0)
        state.fullPercent = 80
        guard case .running(let s) = CalibrationCycle.advance(state, snapshot: snapshot(80), now: t0) else {
            Issue.record("expected running")
            return
        }
        #expect(s.phase == .dischargeToFloor)
        var recharging = s
        recharging.phase = .rechargeToFull
        #expect(CalibrationCycle.advance(recharging, snapshot: snapshot(80), now: t0) == .finished)
    }

    @Test func stateWithoutFullPercentDecodes() throws {
        let json = #"{"phase":"holdFull","startedAt":0,"phaseStartedAt":0,"restoreLimit":80,"floorPercent":15,"holdMinutes":60,"isManual":true}"#
        let state = try JSONDecoder().decode(CycleState.self, from: Data(json.utf8))
        #expect(state.fullPercent == 100)
        #expect(state.phase == .holdFull)
    }

    @Test func stateRoundTripsThroughJSON() throws {
        let state = started()
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(CycleState.self, from: data) == state)
    }
}

@Suite struct CycleScheduleTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func nextStartIsIntervalDaysLaterAtTheStartHour() {
        var settings = CycleSettings.default
        settings.intervalDays = 7
        settings.startHour = 20
        #expect(CycleSchedule.nextStart(after: date(1, 9, 30), settings: settings, calendar: calendar) == date(8, 20))
    }

    @Test func startsOnlyWhenDueAndPluggedIn() {
        var settings = CycleSettings.default
        settings.intervalDays = 7
        let reference = date(1, 9)
        let before = date(8, 19, 59)
        let after = date(8, 20)
        #expect(!CycleSchedule.shouldStart(now: before, reference: reference, settings: settings, snapshot: snapshot(80), calendar: calendar))
        #expect(CycleSchedule.shouldStart(now: after, reference: reference, settings: settings, snapshot: snapshot(80), calendar: calendar))
        #expect(!CycleSchedule.shouldStart(
            now: after, reference: reference, settings: settings, snapshot: snapshot(80, pluggedIn: false), calendar: calendar))
        settings.isScheduled = false
        #expect(!CycleSchedule.shouldStart(now: after, reference: reference, settings: settings, snapshot: snapshot(80), calendar: calendar))
    }
}
