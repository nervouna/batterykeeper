import BatteryKeeperCore
import Foundation
import Testing

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

@Suite struct AdapterLeaseTests {
    @Test func adapterIsOnWithoutALease() {
        #expect(AdapterLease().adapterEnabled(now: t0, percent: 80))
    }

    @Test func leaseCutsUntilItExpires() {
        var lease = AdapterLease()
        lease.request(enabled: false, duration: 90, now: t0)
        #expect(!lease.adapterEnabled(now: t0.addingTimeInterval(89), percent: 80))
        #expect(lease.adapterEnabled(now: t0.addingTimeInterval(90), percent: 80))
        #expect(lease.remaining(now: t0.addingTimeInterval(30)) == 60)
    }

    @Test func leaseIsCappedAtTheMaximum() {
        var lease = AdapterLease()
        lease.request(enabled: false, duration: 10_000, now: t0)
        #expect(lease.expiresAt == t0.addingTimeInterval(AdapterLease.maximumDuration))
    }

    @Test func hardFloorAndUnknownChargeRestoreTheAdapter() {
        var lease = AdapterLease()
        lease.request(enabled: false, duration: 90, now: t0)
        #expect(lease.adapterEnabled(now: t0, percent: AdapterLease.hardFloorPercent))
        #expect(!lease.adapterEnabled(now: t0, percent: AdapterLease.hardFloorPercent + 1))
        #expect(lease.adapterEnabled(now: t0, percent: nil))
    }

    @Test func enablingOrZeroDurationEndsTheLease() {
        var lease = AdapterLease()
        lease.request(enabled: false, duration: 90, now: t0)
        lease.request(enabled: true, duration: 90, now: t0)
        #expect(lease.expiresAt == nil)
        lease.request(enabled: false, duration: 0, now: t0)
        #expect(lease.expiresAt == nil)
    }
}

@Suite struct BatteryPropertiesTests {
    /// Trimmed from a MacBookPro18,1 on macOS 27, plugged in and held at 79 %.
    static var properties: [String: Any] { [
        "CurrentCapacity": 79,
        "ExternalConnected": true,
        "IsCharging": false,
        "FullyCharged": false,
        "Voltage": 12081,
        "InstantAmperage": NSNumber(value: Int64(-1234)),
        "Amperage": 0,
        "CycleCount": 242,
        "DesignCapacity": 8694,
        "AvgTimeToFull": 65535,
        "TimeRemaining": 65535,
        "BatteryData": ["FullChargeCapacity": 7271, "NominalChargeCapacity": 7515, "DesignCapacity": 8694],
        "PowerTelemetryData": ["SystemPowerIn": 26324, "SystemLoad": 26324],
        "AdapterDetails": ["Watts": 90],
    ] }

    @Test func parsesTheRegistryEntry() throws {
        let s = try #require(BatteryProperties.snapshot(from: Self.properties, temperature: 30.4, date: t0))
        #expect(s.percent == 79)
        #expect(s.isPluggedIn && !s.isCharging)
        #expect(s.voltage == 12.081)
        #expect(s.amperage == -1.234)
        #expect(s.temperature == 30.4)
        #expect(s.cycleCount == 242)
        #expect(s.fullChargeCapacity == 7271)
        #expect(s.nominalChargeCapacity == 7515)
        #expect(s.designCapacity == 8694)
        #expect(s.minutesRemaining == nil)
        #expect(s.adapterWatts == 90)
        #expect(s.systemLoad == 26.324)
        #expect(abs((s.health ?? 0) - 0.8644) < 0.001)
    }

    @Test func timeRemainingOnBattery() throws {
        var properties = Self.properties
        properties["ExternalConnected"] = false
        properties["TimeRemaining"] = 185
        let s = try #require(BatteryProperties.snapshot(from: properties, temperature: nil, date: t0))
        #expect(s.minutesRemaining == 185)
        #expect(s.adapterWatts == nil)
    }

    @Test func noChargeLevelNoSnapshot() {
        #expect(BatteryProperties.snapshot(from: [:], temperature: nil, date: t0) == nil)
    }
}

@Suite struct BatteryStatusTests {
    private func s(_ percent: Int, plugged: Bool, charging: Bool, amperage: Double = 0) -> BatterySnapshot {
        BatterySnapshot(date: t0, percent: percent, isPluggedIn: plugged, isCharging: charging, amperage: amperage)
    }

    @Test func statuses() {
        #expect(BatteryStatus(s(50, plugged: false, charging: false, amperage: -1)) == .onBattery)
        #expect(BatteryStatus(s(50, plugged: true, charging: true, amperage: 2)) == .charging)
        #expect(BatteryStatus(s(80, plugged: true, charging: false)) == .heldAtLimit)
        #expect(BatteryStatus(s(100, plugged: true, charging: false)) == .full)
        #expect(BatteryStatus(s(90, plugged: true, charging: false, amperage: -1.5)) == .dischargingOnPower)
    }
}

@Suite struct StatusIconTests {
    private let snapshot = BatterySnapshot(
        date: t0, percent: 79, isPluggedIn: false, isCharging: false, voltage: 12, amperage: -0.75,
        temperature: 30.6, minutesRemaining: 185, systemLoad: 8.6)

    @Test func composesTheChosenParts() {
        var settings = IconSettings.default
        settings.showSystemPower = true
        settings.showBatteryPower = true
        settings.showTemperature = true
        settings.showTimeRemaining = true
        let model = StatusIconModel.make(snapshot: snapshot, settings: settings, cycleRunning: false)
        #expect(model.text == "79% 9W \u{2212}9W 31° 3:05")
        #expect(model.fill == 0.79)
        #expect(model.badge == .none)
        #expect(model.status == .onBattery)
    }

    @Test func textStyleFallsBackToThePercent() {
        var settings = IconSettings.default
        settings.style = .text
        settings.showPercent = false
        #expect(StatusIconModel.make(snapshot: snapshot, settings: settings, cycleRunning: false).text == "79%")
        settings.style = .battery
        #expect(StatusIconModel.make(snapshot: snapshot, settings: settings, cycleRunning: false).text == "")
    }

    @Test func badges() {
        var charging = snapshot
        charging.isPluggedIn = true
        charging.isCharging = true
        #expect(StatusIconModel.make(snapshot: charging, settings: .default, cycleRunning: false).badge == .charging)
        #expect(StatusIconModel.make(snapshot: charging, settings: .default, cycleRunning: true).badge == .cycle)
        var held = charging
        held.isCharging = false
        held.amperage = 0
        #expect(StatusIconModel.make(snapshot: held, settings: .default, cycleRunning: false).badge == .held)
    }

    @Test func lowOnlyOnBattery() {
        var low = snapshot
        low.percent = 20
        #expect(StatusIconModel.make(snapshot: low, settings: .default, cycleRunning: false).isLow)
        low.isPluggedIn = true
        #expect(!StatusIconModel.make(snapshot: low, settings: .default, cycleRunning: false).isLow)
    }

    @Test func noSnapshot() {
        #expect(StatusIconModel.make(snapshot: nil, settings: .default, cycleRunning: false).text == "--")
    }

    @Test func signedWatts() {
        #expect(IconText.signedWatts(12.4) == "+12W")
        #expect(IconText.signedWatts(-0.4) == "0W")
        #expect(IconText.signedWatts(-7.6) == "\u{2212}8W")
        #expect(IconText.duration(minutes: 59) == "0:59")
    }
}

@Suite struct SettingsTests {
    @Test func missingKeysTakeTheirDefaults() {
        let settings = AppSettings.decode(Data(#"{"icon": {"style": "ring"}, "cycle": {"intervalDays": 14}}"#.utf8))
        #expect(settings.icon.style == .ring)
        #expect(settings.icon.showPercent)
        #expect(settings.cycle.intervalDays == 14)
        #expect(settings.cycle.floorPercent == CycleSettings.default.floorPercent)
    }

    @Test func unreadableDataIsTheDefault() {
        #expect(AppSettings.decode(Data("nonsense".utf8)) == .default)
        #expect(AppSettings.decode(nil) == .default)
        #expect(AppSettings.decode(Data(#"{"icon": {"style": "hexagon"}}"#.utf8)).icon.style == .battery)
    }

    @Test func roundTrips() {
        var settings = AppSettings.default
        settings.icon.colorful = true
        settings.cycle.holdMinutes = 30
        #expect(AppSettings.decode(settings.encoded()) == settings)
    }
}

@Suite struct EventDetectorTests {
    private func s(_ percent: Int, plugged: Bool, charging: Bool, at seconds: TimeInterval) -> BatterySnapshot {
        BatterySnapshot(date: t0.addingTimeInterval(seconds), percent: percent, isPluggedIn: plugged, isCharging: charging)
    }

    @Test func detectsChanges() {
        #expect(EventDetector.events(from: nil, to: s(50, plugged: true, charging: true, at: 0)).isEmpty)
        let plug = EventDetector.events(from: s(50, plugged: false, charging: false, at: 0), to: s(50, plugged: true, charging: true, at: 5))
        #expect(plug.map(\.kind) == [.pluggedIn, .chargingStarted])
        let full = EventDetector.events(from: s(99, plugged: true, charging: true, at: 0), to: s(100, plugged: true, charging: false, at: 5))
        #expect(full.map(\.kind) == [.chargingStopped, .fullyCharged])
    }
}

@Suite struct DownsampleTests {
    @Test func averagesPerBucketAndKeepsGaps() {
        let items: [(TimeInterval, Double?)] = [(0, 10), (30, 20), (59, nil), (60, 40), (300, 50)]
        let points = Downsample.average(items, bucket: 60, date: { t0.addingTimeInterval($0.0) }, value: { $0.1 })
        let base = (t0.timeIntervalSince1970 / 60).rounded(.down) * 60
        #expect(points.count == 3)
        #expect(points[0] == ChartPoint(date: Date(timeIntervalSince1970: base), value: 15))
        #expect(points[1].value == 40)
        #expect(points[2].value == 50)
    }

    @Test func dayKey() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 23))!
        #expect(DailyHealth.dayKey(for: date, calendar: calendar) == "2026-03-07")
    }
}
