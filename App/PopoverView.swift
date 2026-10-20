import BatteryKeeperCore
import BatteryKeeperSystem
import SwiftUI

/// The popover under the menu bar item.
struct PopoverView: View {
    let model: AppModel
    let openStatistics: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            PowerFlowView(snapshot: model.snapshot)
            Divider()
            limitSection
            Divider()
            cycleSection
            if let error = model.lastError {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(verbatim: error).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button {
                        model.clearError()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            HStack {
                Button("Statistics…", action: openStatistics)
                Button("Settings…", action: openSettings)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: model.snapshot.map { IconText.percent($0.percent) } ?? "--")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: Texts.status(model.snapshot.map(BatteryStatus.init)))
                    .font(.headline)
                if let snapshot = model.snapshot {
                    Text(verbatim: detailLine(snapshot)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private func detailLine(_ snapshot: BatterySnapshot) -> String {
        var parts: [String] = []
        if let minutes = snapshot.minutesRemaining {
            parts.append(
                snapshot.isCharging
                    ? String(localized: "\(IconText.duration(minutes: minutes)) to full")
                    : String(localized: "\(IconText.duration(minutes: minutes)) remaining"))
        }
        if let temperature = snapshot.temperature {
            parts.append(String(format: "%.1f °C", temperature))
        }
        if let health = snapshot.health {
            parts.append(String(localized: "Health \(Int((health * 100).rounded()))%"))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var limitSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Charge limit").font(.headline)
                Spacer()
                if model.cycle != nil {
                    Text("Restored after the cycle").font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.limitState.isSupported {
                Picker(selection: Binding(get: { model.displayedLimit }, set: { model.setLimit($0) })) {
                    ForEach(model.limitState.available, id: \.self) { limit in
                        Text(verbatim: Texts.limit(limit)).tag(limit)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Button("Charge to Full Now") { model.chargeToFullNow() }
                    .controlSize(.small)
                    .disabled(model.cycle != nil || model.limitState.limit >= 100)
            } else {
                Text("This Mac does not offer the system charge limit (macOS 26.4 or later on Apple silicon).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var cycleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Calibration cycle").font(.headline)
            if let cycle = model.cycle {
                Text(verbatim: String(localized: "Phase \(cycle.phase.number) of \(CyclePhase.allCases.count): \(Texts.phase(of: cycle))"))
                    .font(.callout)
                if let end = cycle.holdEndsAt {
                    Text(verbatim: String(localized: "Holding until \(Texts.dateTime(end))"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(verbatim: String(localized: "Started \(Texts.dateTime(cycle.startedAt))"))
                    .font(.caption).foregroundStyle(.secondary)
                if CalibrationCycle.directive(for: cycle.phase).preventSleep {
                    Text("The Mac stays awake while discharging. Closing the lid pauses the cycle.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Stop Cycle", role: .destructive) { model.cancelCycle() }
                    .controlSize(.small)
            } else {
                if let next = model.nextScheduledCycle {
                    Text(verbatim: String(localized: "Next: \(Texts.dateTime(next))"))
                        .font(.callout)
                } else {
                    Text("Scheduled cycles are off.").font(.callout)
                }
                switch model.helperStatus {
                case .enabled:
                    Button("Start Cycle Now") { model.startCycle() }
                        .controlSize(.small)
                        .disabled(!model.canStartCycle)
                case .requiresApproval:
                    Text("Allow the BatteryKeeper helper in System Settings to discharge on power.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Login Items…") { model.openLoginItemsSettings() }.controlSize(.small)
                case .notRegistered:
                    Text("A cycle needs the privileged helper to discharge on power.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Install Helper…") { model.installHelper() }
                        .controlSize(.small)
                }
            }
        }
    }
}

/// Adapter → system, and the battery's share.
struct PowerFlowView: View {
    let snapshot: BatterySnapshot?

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                label("powerplug", String(localized: "Adapter"))
                value(snapshot?.systemPowerIn.flatMap { snapshot?.isPluggedIn == true ? $0 : nil })
                if let watts = snapshot?.adapterWatts {
                    Text(verbatim: String(localized: "\(watts) W adapter")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("")
                }
            }
            GridRow {
                label("laptopcomputer", String(localized: "System"))
                value(snapshot?.systemLoad)
                Text("")
            }
            GridRow {
                label("battery.75percent", String(localized: "Battery"))
                Text(verbatim: snapshot.map { IconText.signedWatts($0.batteryPower) } ?? "--")
                    .monospacedDigit()
                Text(verbatim: snapshot.map { String(format: "%.2f V · %.2f A", $0.voltage, $0.amperage) } ?? "")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .font(.callout)
    }

    private func label(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(verbatim: text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
    }

    private func value(_ watts: Double?) -> some View {
        Text(verbatim: watts.map { String(format: "%.1f W", $0) } ?? "--").monospacedDigit()
    }
}
