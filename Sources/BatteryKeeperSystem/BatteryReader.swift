import BatteryKeeperCore
import Foundation
import IOKit
import IOKit.ps

/// Reads the battery from the `AppleSmartBattery` IORegistry entry, and its temperature from the SMC.
/// Needs no privileges.
public final class BatteryReader: Sendable {
    /// Battery temperature in °C (float). Apple silicon no longer publishes it in the IORegistry.
    static let temperatureKey = "TB0T"

    private let smc: SMCClient?

    public init(smc: SMCClient? = try? SMCClient()) {
        self.smc = smc
    }

    public func read(now: Date = Date()) -> BatterySnapshot? {
        guard let properties = Self.properties() else { return nil }
        let temperature = (try? smc?.readFloat(Self.temperatureKey)).flatMap { value -> Double? in
            // An unplausible value means the key means something else on this machine.
            (-20...100).contains(value) ? Double(value) : nil
        }
        return BatteryProperties.snapshot(from: properties, temperature: temperature, date: now)
    }

    /// The charge in percent, read on its own (the helper's floor check).
    public func percent() -> Int? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "CurrentCapacity" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (value as? NSNumber)?.intValue
    }

    static func properties() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == kIOReturnSuccess,
            let dictionary = unmanaged?.takeRetainedValue() as? [String: Any]
        else { return nil }
        return dictionary
    }
}

/// Calls back on the main run loop whenever a power source changes (plug, unplug, charge level).
@MainActor
public final class PowerSourceObserver {
    private var source: CFRunLoopSource?
    private let handler: @MainActor () -> Void

    public init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    public func start() {
        guard source == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard
            let source = IOPSNotificationCreateRunLoopSource(
                { context in
                    guard let context else { return }
                    let observer = Unmanaged<PowerSourceObserver>.fromOpaque(context).takeUnretainedValue()
                    MainActor.assumeIsolated { observer.handler() }
                }, context)?.takeRetainedValue()
        else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        self.source = source
    }

    public func stop() {
        guard let source else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        self.source = nil
    }
}
