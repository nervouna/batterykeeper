import Foundation

/// One recorded sample, as the statistics store keeps it.
public struct StoredSample: Sendable, Equatable {
    public var date: Date
    public var percent: Int
    public var temperature: Double?
    public var voltage: Double
    public var amperage: Double
    public var systemLoad: Double?
    public var systemPowerIn: Double?
    public var adapterWatts: Int?
    public var isPluggedIn: Bool
    public var isCharging: Bool
    /// The daily limit in effect, percent; nil when unknown.
    public var limit: Int?

    public init(snapshot: BatterySnapshot, limit: Int?) {
        self.init(
            date: snapshot.date, percent: snapshot.percent, temperature: snapshot.temperature,
            voltage: snapshot.voltage, amperage: snapshot.amperage, systemLoad: snapshot.systemLoad,
            systemPowerIn: snapshot.systemPowerIn, adapterWatts: snapshot.adapterWatts,
            isPluggedIn: snapshot.isPluggedIn, isCharging: snapshot.isCharging, limit: limit)
    }

    public init(
        date: Date, percent: Int, temperature: Double?, voltage: Double, amperage: Double, systemLoad: Double?,
        systemPowerIn: Double?, adapterWatts: Int?, isPluggedIn: Bool, isCharging: Bool, limit: Int?
    ) {
        self.date = date
        self.percent = percent
        self.temperature = temperature
        self.voltage = voltage
        self.amperage = amperage
        self.systemLoad = systemLoad
        self.systemPowerIn = systemPowerIn
        self.adapterWatts = adapterWatts
        self.isPluggedIn = isPluggedIn
        self.isCharging = isCharging
        self.limit = limit
    }

    public var batteryPower: Double { voltage * amperage }
}

/// The battery's health on one day.
public struct DailyHealth: Sendable, Equatable {
    /// "yyyy-MM-dd" in local time.
    public var day: String
    public var fullChargeCapacity: Int
    public var nominalChargeCapacity: Int
    public var designCapacity: Int
    public var cycleCount: Int

    public init(day: String, fullChargeCapacity: Int, nominalChargeCapacity: Int, designCapacity: Int, cycleCount: Int) {
        self.day = day
        self.fullChargeCapacity = fullChargeCapacity
        self.nominalChargeCapacity = nominalChargeCapacity
        self.designCapacity = designCapacity
        self.cycleCount = cycleCount
    }

    public init(day: String, snapshot: BatterySnapshot) {
        self.init(
            day: day, fullChargeCapacity: snapshot.fullChargeCapacity,
            nominalChargeCapacity: snapshot.nominalChargeCapacity, designCapacity: snapshot.designCapacity,
            cycleCount: snapshot.cycleCount)
    }

    /// Same definition as ``BatterySnapshot/health``.
    public var health: Double? {
        guard designCapacity > 0, nominalChargeCapacity > 0 else { return nil }
        return Double(nominalChargeCapacity) / Double(designCapacity)
    }

    /// The local calendar day of `date` as stored.
    public static func dayKey(for date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let year = c.year ?? 0, month = c.month ?? 0, day = c.day ?? 0
        return String(year) + "-" + (month < 10 ? "0" : "") + String(month) + "-" + (day < 10 ? "0" : "") + String(day)
    }
}

/// A point of a chart line.
public struct ChartPoint: Sendable, Equatable {
    public var date: Date
    public var value: Double

    public init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

public enum Downsample {
    /// Averages the values in buckets of `bucket` seconds, aligned to the epoch, dated at the bucket's start.
    /// Items whose value is nil are left out; empty buckets give no point, so gaps (sleep) stay gaps.
    public static func average<Item>(
        _ items: [Item], bucket: TimeInterval, date: (Item) -> Date, value: (Item) -> Double?
    ) -> [ChartPoint] {
        guard bucket > 0 else {
            return items.compactMap { item in value(item).map { ChartPoint(date: date(item), value: $0) } }
        }
        var sums: [Int: (sum: Double, count: Int)] = [:]
        for item in items {
            guard let v = value(item) else { continue }
            let key = Int((date(item).timeIntervalSince1970 / bucket).rounded(.down))
            let current = sums[key] ?? (0, 0)
            sums[key] = (current.sum + v, current.count + 1)
        }
        return sums.keys.sorted().map { key in
            let entry = sums[key]!
            return ChartPoint(date: Date(timeIntervalSince1970: Double(key) * bucket), value: entry.sum / Double(entry.count))
        }
    }

    /// The bucket size that keeps a span of `span` seconds at about `points` points, never below `minimum`.
    public static func bucket(for span: TimeInterval, points: Int, minimum: TimeInterval) -> TimeInterval {
        max(minimum, span / Double(max(points, 1)))
    }
}
