import Foundation

/// Everything the user configures. Stored as JSON; a missing or unreadable key takes its default.
public struct AppSettings: Codable, Sendable, Equatable {
    public var icon: IconSettings
    public var cycle: CycleSettings

    public static let `default` = AppSettings(icon: .default, cycle: .default)

    public init(icon: IconSettings, cycle: CycleSettings) {
        self.icon = icon
        self.cycle = cycle
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        icon = (try? c.decodeIfPresent(IconSettings.self, forKey: .icon)) ?? .default
        cycle = (try? c.decodeIfPresent(CycleSettings.self, forKey: .cycle)) ?? .default
    }

    public static func decode(_ data: Data?) -> AppSettings {
        guard let data, let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return .default }
        return settings
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }
}
