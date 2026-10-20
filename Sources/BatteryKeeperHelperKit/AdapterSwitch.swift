import BatteryKeeperSystem
import Foundation

/// Switches the power adapter on and off. Cutting it makes the Mac run from the battery while plugged in.
public protocol AdapterSwitch: Sendable {
    func setAdapterEnabled(_ enabled: Bool) throws
    func isAdapterEnabled() throws -> Bool
}

/// The adapter switch of Apple silicon firmware since macOS 15: SMC key `CHIE`, one byte, `0x08` cuts the
/// adapter and `0x00` restores it. Writing needs root.
public final class SMCAdapterSwitch: AdapterSwitch {
    static let key = "CHIE"
    static let cutValue: UInt8 = 0x08
    static let enabledValue: UInt8 = 0x00

    private let smc: SMCClient

    /// Fails when the SMC cannot be opened or has no `CHIE` key.
    public init() throws {
        smc = try SMCClient()
        let info = try smc.keyInfo(Self.key)
        guard info.size == 1 else {
            throw SMCError(key: Self.key, kernelResult: 0, smcResult: 0)
        }
    }

    public func setAdapterEnabled(_ enabled: Bool) throws {
        try smc.write(Self.key, [enabled ? Self.enabledValue : Self.cutValue])
    }

    public func isAdapterEnabled() throws -> Bool {
        let value = try smc.read(Self.key).first ?? 0
        return value & Self.cutValue == 0
    }
}

/// Stands in when the Mac has no adapter switch: the adapter is always on and cannot be cut.
public struct UnavailableAdapterSwitch: AdapterSwitch {
    public struct Unavailable: Error, CustomStringConvertible {
        public var description: String { "this Mac has no adapter switch (SMC key CHIE)" }
    }

    public init() {}

    public func setAdapterEnabled(_ enabled: Bool) throws {
        if !enabled { throw Unavailable() }
    }

    public func isAdapterEnabled() throws -> Bool { true }
}
