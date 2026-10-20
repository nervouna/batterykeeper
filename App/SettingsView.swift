import BatteryKeeperCore
import BatteryKeeperSystem
import SwiftUI

/// The Settings window.
struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, value in model.setLaunchAtLogin(value) }
                LabeledContent("Helper") {
                    HStack {
                        Text(verbatim: Texts.helper(model.helperStatus, reachable: model.helperReachable))
                            .foregroundStyle(.secondary)
                        switch model.helperStatus {
                        case .enabled:
                            Button("Remove") { model.uninstallHelper() }
                        case .requiresApproval:
                            Button("Open Login Items…") { model.openLoginItemsSettings() }
                        case .notRegistered:
                            Button("Install…") { model.installHelper() }
                        }
                    }
                }
                Text("The helper runs as root and only switches the power adapter off and on for calibration cycles. It restores the adapter on its own when BatteryKeeper quits, the Mac sleeps or the charge falls to 10%.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Menu bar") {
                Picker("Style", selection: $model.settings.icon.style) {
                    ForEach(IconStyle.allCases, id: \.self) { Text(verbatim: Texts.style($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Percentage", isOn: $model.settings.icon.showPercent)
                Toggle("System power (W)", isOn: $model.settings.icon.showSystemPower)
                Toggle("Battery power (± W)", isOn: $model.settings.icon.showBatteryPower)
                Toggle("Temperature", isOn: $model.settings.icon.showTemperature)
                Toggle("Time remaining", isOn: $model.settings.icon.showTimeRemaining)
                Toggle("Colored status", isOn: $model.settings.icon.colorful)
            }

            Section("Calibration cycle") {
                Toggle("Run on a schedule", isOn: $model.settings.cycle.isScheduled)
                Stepper(value: $model.settings.cycle.intervalDays, in: CycleSettings.intervalRange) {
                    LabeledContent("Every", value: String(localized: "\(model.settings.cycle.intervalDays) days"))
                }
                Picker("Start from", selection: $model.settings.cycle.startHour) {
                    ForEach(0..<24, id: \.self) { hour in
                        Text(verbatim: String(format: "%02d:00", hour)).tag(hour)
                    }
                }
                Stepper(value: $model.settings.cycle.floorPercent, in: CycleSettings.floorRange, step: 5) {
                    LabeledContent("Discharge to", value: "\(model.settings.cycle.floorPercent)%")
                }
                Stepper(value: $model.settings.cycle.holdMinutes, in: CycleSettings.holdRange, step: 15) {
                    LabeledContent("Hold at 100% for", value: String(localized: "\(model.settings.cycle.holdMinutes) min"))
                }
                if let next = model.nextScheduledCycle {
                    LabeledContent("Next cycle", value: Texts.dateTime(next))
                }
                Text("A cycle charges to 100%, discharges on power to the floor, charges to 100% again, holds, then discharges to the daily limit. A due cycle starts when the Mac is awake and plugged in. Settings apply to the next cycle.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 520)
        .onAppear {
            launchAtLogin = model.launchAtLogin
            model.checkHelper()
        }
    }
}
