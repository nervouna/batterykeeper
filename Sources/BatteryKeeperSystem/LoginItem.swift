import Foundation
import IOKit.pwr_mgt
import ServiceManagement

/// Whether the app starts at login: the main app's `SMAppService`. Works only inside the app bundle.
@MainActor
public struct LoginItem {
    public init() {}

    public var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    public func setEnabled(_ enabled: Bool) throws(HelperError) {
        let status = SMAppService.mainApp.status
        let registered = status == .enabled || status == .requiresApproval
        guard registered != enabled else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            throw HelperError(description: error.localizedDescription)
        }
    }
}

/// Keeps the Mac from sleeping while idle (the display may still sleep), for the discharge phases.
@MainActor
public final class SleepAssertion {
    private var assertion: IOPMAssertionID = 0
    private var held = false

    public init() {}

    public var isHeld: Bool { held }

    public func set(_ hold: Bool, reason: String) {
        if hold == held { return }
        if hold {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString, &id)
            if result == kIOReturnSuccess {
                assertion = id
                held = true
            }
        } else {
            IOPMAssertionRelease(assertion)
            assertion = 0
            held = false
        }
    }
}
