import Foundation

/// How the menu bar item draws the battery.
public enum IconStyle: String, Codable, Sendable, CaseIterable {
    /// A battery outline filled to the charge level.
    case battery
    /// A ring filled to the charge level.
    case ring
    /// No drawing, the text only.
    case text
}

/// What the menu bar item shows.
public struct IconSettings: Codable, Sendable, Equatable {
    public var style: IconStyle
    public var showPercent: Bool
    /// The whole system's power draw, watts.
    public var showSystemPower: Bool
    /// Power into or out of the battery, signed watts.
    public var showBatteryPower: Bool
    public var showTemperature: Bool
    public var showTimeRemaining: Bool
    /// Draw the state in colour instead of as a template image.
    public var colorful: Bool

    public static let `default` = IconSettings(
        style: .battery, showPercent: true, showSystemPower: false, showBatteryPower: false,
        showTemperature: false, showTimeRemaining: false, colorful: false)

    public init(
        style: IconStyle, showPercent: Bool, showSystemPower: Bool, showBatteryPower: Bool,
        showTemperature: Bool, showTimeRemaining: Bool, colorful: Bool
    ) {
        self.style = style
        self.showPercent = showPercent
        self.showSystemPower = showSystemPower
        self.showBatteryPower = showBatteryPower
        self.showTemperature = showTemperature
        self.showTimeRemaining = showTimeRemaining
        self.colorful = colorful
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.default
        style = (try? c.decodeIfPresent(IconStyle.self, forKey: .style)) ?? d.style
        showPercent = try c.decodeIfPresent(Bool.self, forKey: .showPercent) ?? d.showPercent
        showSystemPower = try c.decodeIfPresent(Bool.self, forKey: .showSystemPower) ?? d.showSystemPower
        showBatteryPower = try c.decodeIfPresent(Bool.self, forKey: .showBatteryPower) ?? d.showBatteryPower
        showTemperature = try c.decodeIfPresent(Bool.self, forKey: .showTemperature) ?? d.showTemperature
        showTimeRemaining = try c.decodeIfPresent(Bool.self, forKey: .showTimeRemaining) ?? d.showTimeRemaining
        colorful = try c.decodeIfPresent(Bool.self, forKey: .colorful) ?? d.colorful
    }
}

/// The small symbol next to or inside the drawing.
public enum IconBadge: String, Sendable, Equatable {
    case none
    case charging
    case held
    case discharging
    case cycle
}

/// Everything the menu bar item needs to draw itself; produced from a snapshot and the settings.
public struct StatusIconModel: Sendable, Equatable {
    public var style: IconStyle
    /// Charge level, 0–1.
    public var fill: Double
    public var badge: IconBadge
    public var status: BatteryStatus?
    /// The text after the drawing, empty for none.
    public var text: String
    public var colorful: Bool
    /// Low enough to draw in the warning colour.
    public var isLow: Bool

    /// On battery at or below this charge, percent, the colourful icon turns red.
    public static let lowPercent = 20

    public static func make(snapshot: BatterySnapshot?, settings: IconSettings, cycleRunning: Bool) -> StatusIconModel {
        guard let snapshot else {
            return StatusIconModel(
                style: settings.style, fill: 0, badge: .none, status: nil, text: "--", colorful: settings.colorful,
                isLow: false)
        }
        let status = BatteryStatus(snapshot)
        let badge: IconBadge
        if cycleRunning {
            badge = .cycle
        } else {
            switch status {
            case .charging: badge = .charging
            case .heldAtLimit: badge = .held
            case .dischargingOnPower: badge = .discharging
            case .onBattery, .full: badge = .none
            }
        }

        var parts: [String] = []
        if settings.showPercent { parts.append(IconText.percent(snapshot.percent)) }
        if settings.showSystemPower, let load = snapshot.systemLoad { parts.append(IconText.watts(load)) }
        if settings.showBatteryPower { parts.append(IconText.signedWatts(snapshot.batteryPower)) }
        if settings.showTemperature, let t = snapshot.temperature { parts.append(IconText.temperature(t)) }
        if settings.showTimeRemaining, let m = snapshot.minutesRemaining { parts.append(IconText.duration(minutes: m)) }
        // The text style must show something.
        if parts.isEmpty && settings.style == .text { parts.append(IconText.percent(snapshot.percent)) }

        return StatusIconModel(
            style: settings.style,
            fill: Double(snapshot.percent) / 100,
            badge: badge,
            status: status,
            text: parts.joined(separator: " "),
            colorful: settings.colorful,
            isLow: status == .onBattery && snapshot.percent <= lowPercent)
    }
}

/// Language-neutral texts for numbers: the menu bar and the charts use them as they are.
public enum IconText {
    public static func percent(_ value: Int) -> String { "\(value)%" }

    public static func watts(_ value: Double) -> String {
        "\(Int(value.rounded()))W"
    }

    /// "+12W" while charging, "−8W" (minus sign) while discharging, "0W" when idle.
    public static func signedWatts(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        if rounded > 0 { return "+\(rounded)W" }
        if rounded < 0 { return "\u{2212}\(-rounded)W" }
        return "0W"
    }

    public static func temperature(_ celsius: Double) -> String {
        "\(Int(celsius.rounded()))°"
    }

    /// "3:05" for 185 minutes.
    public static func duration(minutes: Int) -> String {
        let m = max(0, minutes)
        return "\(m / 60):" + (m % 60 < 10 ? "0" : "") + "\(m % 60)"
    }
}
