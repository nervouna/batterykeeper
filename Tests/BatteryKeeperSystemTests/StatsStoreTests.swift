import BatteryKeeperCore
import BatteryKeeperSystem
import Foundation
import Testing

@Suite struct StatsStoreTests {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("batterykeeper-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("stats.sqlite")
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func sample(_ percent: Int, at seconds: TimeInterval) -> StoredSample {
        StoredSample(
            date: t0.addingTimeInterval(seconds), percent: percent, temperature: seconds > 0 ? 30.5 : nil, voltage: 12.1,
            amperage: -0.5, systemLoad: 8.25, systemPowerIn: nil, adapterWatts: 90, isPluggedIn: true, isCharging: false,
            limit: 80)
    }

    @Test func samplesRoundTripAndPrune() throws {
        let store = try StatsStore(url: url)
        try store.insert(sample(80, at: 0))
        try store.insert(sample(79, at: 60))
        try store.insert(sample(78, at: 120))
        #expect(try store.samples(since: t0) == [sample(80, at: 0), sample(79, at: 60), sample(78, at: 120)])
        #expect(try store.samples(since: t0.addingTimeInterval(61)).map(\.percent) == [78])
        try store.pruneSamples(before: t0.addingTimeInterval(60))
        #expect(try store.samples(since: t0).count == 2)
    }

    @Test func healthIsOneRowADay() throws {
        let store = try StatsStore(url: url)
        try store.upsert(DailyHealth(day: "2026-10-20", fullChargeCapacity: 7271, nominalChargeCapacity: 7515, designCapacity: 8694, cycleCount: 242))
        try store.upsert(DailyHealth(day: "2026-10-20", fullChargeCapacity: 7260, nominalChargeCapacity: 7510, designCapacity: 8694, cycleCount: 243))
        try store.upsert(DailyHealth(day: "2026-10-21", fullChargeCapacity: 7250, nominalChargeCapacity: 7500, designCapacity: 8694, cycleCount: 243))
        let rows = try store.dailyHealth()
        #expect(rows.map(\.day) == ["2026-10-20", "2026-10-21"])
        #expect(rows[0].cycleCount == 243)
    }

    @Test func eventsNewestFirst() throws {
        let store = try StatsStore(url: url)
        try store.insert(BatteryEvent(date: t0, kind: .pluggedIn, detail: "50"))
        try store.insert(BatteryEvent(date: t0.addingTimeInterval(5), kind: .cyclePhase, detail: "dischargeToFloor"))
        #expect(try store.events(limit: 10).map(\.kind) == [.cyclePhase, .pluggedIn])
        #expect(try store.events(limit: 1).count == 1)
    }

    @Test func reopensAnExistingDatabase() throws {
        do {
            let store = try StatsStore(url: url)
            try store.insert(sample(80, at: 0))
        }
        let reopened = try StatsStore(url: url)
        #expect(try reopened.samples(since: t0).count == 1)
    }
}
