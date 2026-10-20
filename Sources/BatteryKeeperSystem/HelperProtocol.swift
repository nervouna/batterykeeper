import Foundation

public enum HelperConstants {
    /// Launchd label and Mach service name of the privileged helper.
    public static let label = "io.damao.batterykeeper.helper"
    /// The launchd plist's name inside `Contents/Library/LaunchDaemons`.
    public static let plistName = "io.damao.batterykeeper.helper.plist"
    /// The app's bundle ID, the only client the helper accepts.
    public static let appIdentifier = "io.damao.batterykeeper"
    /// Bumped whenever the protocol changes, so that the app can tell an outdated helper.
    public static let protocolVersion = 1
    /// How long the app asks the helper to keep the adapter cut, seconds. The app renews well before.
    public static let leaseDuration: TimeInterval = 90
}

/// The privileged helper's XPC interface. It switches the adapter and nothing else.
@objc public protocol BatteryKeeperHelperProtocol {
    func protocolVersion(reply: @escaping @Sendable (Int) -> Void)

    /// Cuts the adapter for `leaseSeconds` (`enabled` false) or restores it (`enabled` true). The helper
    /// restores the adapter by itself when the lease runs out, the connection ends, the system goes to
    /// sleep or the charge reaches the hard floor.
    func setAdapterEnabled(_ enabled: Bool, leaseSeconds: Double, reply: @escaping @Sendable (NSError?) -> Void)

    /// Whether the adapter powers the Mac and how long the current lease has left.
    func adapterState(reply: @escaping @Sendable (Bool, Double, NSError?) -> Void)
}
