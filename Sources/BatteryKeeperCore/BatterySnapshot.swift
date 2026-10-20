import Foundation

/// One reading of the battery and the power adapter.
public struct BatterySnapshot: Sendable, Equatable, Codable {
    public var date: Date
    /// State of charge in percent, 0–100, as macOS shows it.
    public var percent: Int
    /// An adapter is connected (it may still be cut off by the helper).
    public var isPluggedIn: Bool
    public var isCharging: Bool
    public var isFullyCharged: Bool
    /// Volts.
    public var voltage: Double
    /// Amperes, positive while the battery charges and negative while it discharges.
    public var amperage: Double
    /// Battery temperature in degrees Celsius, nil when it cannot be read.
    public var temperature: Double?
    public var cycleCount: Int
    /// Capacities in mAh.
    public var fullChargeCapacity: Int
    public var nominalChargeCapacity: Int
    public var designCapacity: Int
    /// Minutes to full while charging, to empty on battery; nil when macOS has no estimate.
    public var minutesRemaining: Int?
    /// Rated power of the connected adapter in watts, nil without one.
    public var adapterWatts: Int?
    /// Watts the system draws from the adapter, nil when not reported.
    public var systemPowerIn: Double?
    /// Watts the whole system consumes, nil when not reported.
    public var systemLoad: Double?

    public init(
        date: Date,
        percent: Int,
        isPluggedIn: Bool,
        isCharging: Bool,
        isFullyCharged: Bool = false,
        voltage: Double = 0,
        amperage: Double = 0,
        temperature: Double? = nil,
        cycleCount: Int = 0,
        fullChargeCapacity: Int = 0,
        nominalChargeCapacity: Int = 0,
        designCapacity: Int = 0,
        minutesRemaining: Int? = nil,
        adapterWatts: Int? = nil,
        systemPowerIn: Double? = nil,
        systemLoad: Double? = nil
    ) {
        self.date = date
        self.percent = percent
        self.isPluggedIn = isPluggedIn
        self.isCharging = isCharging
        self.isFullyCharged = isFullyCharged
        self.voltage = voltage
        self.amperage = amperage
        self.temperature = temperature
        self.cycleCount = cycleCount
        self.fullChargeCapacity = fullChargeCapacity
        self.nominalChargeCapacity = nominalChargeCapacity
        self.designCapacity = designCapacity
        self.minutesRemaining = minutesRemaining
        self.adapterWatts = adapterWatts
        self.systemPowerIn = systemPowerIn
        self.systemLoad = systemLoad
    }

    /// Watts into (positive) or out of (negative) the battery.
    public var batteryPower: Double { voltage * amperage }

    /// Nominal charge capacity over design capacity, 0–1 (roughly what System Settings calls
    /// "Maximum Capacity"); nil when the design capacity is unknown.
    public var health: Double? {
        guard designCapacity > 0, nominalChargeCapacity > 0 else { return nil }
        return Double(nominalChargeCapacity) / Double(designCapacity)
    }
}

/// Turns the properties of the `AppleSmartBattery` IORegistry entry into a snapshot.
public enum BatteryProperties {
    /// macOS reports "no estimate" as this many minutes.
    static let noEstimate = 65535

    /// - Parameters:
    ///   - properties: the entry's properties, as `IORegistryEntryCreateCFProperties` returns them.
    ///   - temperature: the battery temperature read elsewhere (the SMC on Apple silicon), in °C.
    /// - Returns: nil when the properties carry no charge level.
    public static func snapshot(from properties: [String: Any], temperature: Double?, date: Date) -> BatterySnapshot? {
        guard let percent = int(properties["CurrentCapacity"]) else { return nil }
        let data = properties["BatteryData"] as? [String: Any] ?? [:]
        let telemetry = properties["PowerTelemetryData"] as? [String: Any] ?? [:]
        let adapter = properties["AdapterDetails"] as? [String: Any]

        let pluggedIn = bool(properties["ExternalConnected"]) ?? false
        let charging = bool(properties["IsCharging"]) ?? false
        let milliamps = int(properties["InstantAmperage"]) ?? int(properties["Amperage"]) ?? 0
        let millivolts = int(properties["Voltage"]) ?? int(properties["AppleRawBatteryVoltage"]) ?? 0

        var minutes: Int?
        if charging {
            minutes = estimate(properties["AvgTimeToFull"])
        } else if !pluggedIn {
            minutes = estimate(properties["TimeRemaining"]) ?? estimate(properties["AvgTimeToEmpty"])
        }

        // Older machines report the temperature here, in hundredths of a degree.
        let reportedTemperature = int(properties["Temperature"]).map { Double($0) / 100 }

        return BatterySnapshot(
            date: date,
            percent: min(max(percent, 0), 100),
            isPluggedIn: pluggedIn,
            isCharging: charging,
            isFullyCharged: bool(properties["FullyCharged"]) ?? false,
            voltage: Double(millivolts) / 1000,
            amperage: Double(milliamps) / 1000,
            temperature: temperature ?? reportedTemperature,
            cycleCount: int(properties["CycleCount"]) ?? 0,
            fullChargeCapacity: int(data["FullChargeCapacity"]) ?? int(properties["AppleRawMaxCapacity"]) ?? 0,
            nominalChargeCapacity: int(data["NominalChargeCapacity"]) ?? int(properties["NominalChargeCapacity"]) ?? 0,
            designCapacity: int(properties["DesignCapacity"]) ?? int(data["DesignCapacity"]) ?? 0,
            minutesRemaining: minutes,
            adapterWatts: pluggedIn ? adapter.flatMap { int($0["Watts"]) }.flatMap { $0 > 0 ? $0 : nil } : nil,
            systemPowerIn: int(telemetry["SystemPowerIn"]).map { Double($0) / 1000 },
            systemLoad: int(telemetry["SystemLoad"]).map { Double($0) / 1000 }
        )
    }

    /// IOKit stores signed values (the amperage) as 64-bit numbers, so read them as `Int64`.
    static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        return Int(truncatingIfNeeded: number.int64Value)
    }

    static func bool(_ value: Any?) -> Bool? {
        (value as? NSNumber)?.boolValue
    }

    static func estimate(_ value: Any?) -> Int? {
        guard let minutes = int(value), minutes > 0, minutes < noEstimate else { return nil }
        return minutes
    }
}
