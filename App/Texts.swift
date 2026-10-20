import BatteryKeeperCore
import BatteryKeeperSystem
import Foundation

/// The interface's words for the model's values. Every text is looked up in `Localizable.xcstrings`.
enum Texts {
    static func status(_ status: BatteryStatus?) -> String {
        switch status {
        case .onBattery: String(localized: "On battery")
        case .charging: String(localized: "Charging")
        case .heldAtLimit: String(localized: "Held at the limit")
        case .full: String(localized: "Fully charged")
        case .dischargingOnPower: String(localized: "Discharging on power")
        case nil: String(localized: "No battery information")
        }
    }

    static func phase(_ phase: CyclePhase, floor: Int, limit: Int) -> String {
        switch phase {
        case .chargeToFull: String(localized: "Charging to 100%")
        case .dischargeToFloor: String(localized: "Discharging to \(floor)%")
        case .rechargeToFull: String(localized: "Recharging to 100%")
        case .holdFull: String(localized: "Holding at 100%")
        case .dischargeToLimit: String(localized: "Discharging to \(limit)%")
        }
    }

    static func phase(of state: CycleState) -> String {
        phase(state.phase, floor: state.floorPercent, limit: state.restoreLimit)
    }

    static func helper(_ status: HelperStatus, reachable: Bool?) -> String {
        switch status {
        case .enabled:
            reachable == false ? String(localized: "Installed, not responding") : String(localized: "Installed")
        case .requiresApproval: String(localized: "Waiting for approval in System Settings")
        case .notRegistered: String(localized: "Not installed")
        }
    }

    static func limit(_ limit: Int) -> String {
        limit >= 100 ? String(localized: "Off") : "\(limit)%"
    }

    static func event(_ event: BatteryEvent) -> String {
        switch event.kind {
        case .appLaunched: return String(localized: "BatteryKeeper started")
        case .pluggedIn: return String(localized: "Plugged in at \(event.detail)%")
        case .unplugged: return String(localized: "Unplugged at \(event.detail)%")
        case .chargingStarted: return String(localized: "Charging started at \(event.detail)%")
        case .chargingStopped: return String(localized: "Charging stopped at \(event.detail)%")
        case .fullyCharged: return String(localized: "Fully charged")
        case .limitChanged:
            return String(localized: "Charge limit set to \(limit(Int(event.detail) ?? 100))")
        case .chargeToFullNow: return String(localized: "Charge to full now")
        case .cycleStarted:
            return event.detail == "manual"
                ? String(localized: "Calibration cycle started by hand")
                : String(localized: "Scheduled calibration cycle started")
        case .cyclePhase:
            guard let phase = CyclePhase(rawValue: event.detail) else { return event.detail }
            return String(localized: "Cycle phase: \(phaseName(phase))")
        case .cycleFinished: return String(localized: "Calibration cycle finished")
        case .cycleCancelled: return String(localized: "Calibration cycle cancelled")
        case .cycleExpired: return String(localized: "Calibration cycle gave up after 72 hours")
        case .helperProblem: return String(localized: "Helper problem: \(event.detail)")
        }
    }

    static func phaseName(_ phase: CyclePhase) -> String {
        switch phase {
        case .chargeToFull: String(localized: "charge to 100%")
        case .dischargeToFloor: String(localized: "discharge to the floor")
        case .rechargeToFull: String(localized: "recharge to 100%")
        case .holdFull: String(localized: "hold at 100%")
        case .dischargeToLimit: String(localized: "discharge to the limit")
        }
    }

    static func style(_ style: IconStyle) -> String {
        switch style {
        case .battery: String(localized: "Battery")
        case .ring: String(localized: "Ring")
        case .text: String(localized: "Text only")
        }
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(.dateTime.month().day().hour().minute())
    }
}
