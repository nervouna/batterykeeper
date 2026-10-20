import BatteryKeeperCore
import Charts
import SwiftUI

/// The Statistics window: health, history, live power and the event log.
struct StatisticsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            Tab("Health", systemImage: "heart") { HealthTab(model: model) }
            Tab("History", systemImage: "chart.xyaxis.line") { HistoryTab(model: model) }
            Tab("Power", systemImage: "bolt") { PowerTab(model: model) }
            Tab("Events", systemImage: "list.bullet") { EventsTab(model: model) }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 440)
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: value).font(.title2.weight(.semibold)).monospacedDigit()
            if let detail {
                Text(verbatim: detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Health

private struct HealthTab: View {
    let model: AppModel
    @State private var rows: [DailyHealth] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let snapshot = model.snapshot {
                HStack {
                    StatTile(
                        title: String(localized: "Health"),
                        value: snapshot.health.map { "\(Int(($0 * 100).rounded()))%" } ?? "--",
                        detail: String(localized: "Nominal / design capacity"))
                    StatTile(title: String(localized: "Cycle count"), value: "\(snapshot.cycleCount)")
                    StatTile(
                        title: String(localized: "Full charge capacity"), value: "\(snapshot.fullChargeCapacity) mAh",
                        detail: String(localized: "Design \(snapshot.designCapacity) mAh"))
                    StatTile(title: String(localized: "Nominal capacity"), value: "\(snapshot.nominalChargeCapacity) mAh")
                }
            }
            if rows.count < 2 {
                ContentUnavailableView(
                    "Not enough history yet", systemImage: "calendar",
                    description: Text("BatteryKeeper records the battery's health once a day."))
            } else {
                Text("Health").font(.headline)
                Chart(rows, id: \.day) { row in
                    if let health = row.health, let date = date(row.day) {
                        LineMark(x: .value("Day", date), y: .value("Health", health * 100))
                            .interpolationMethod(.monotone)
                    }
                }
                .chartYAxisLabel("%")
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(minHeight: 140)
                Text("Cycle count").font(.headline)
                Chart(rows, id: \.day) { row in
                    if let date = date(row.day) {
                        LineMark(x: .value("Day", date), y: .value("Cycles", row.cycleCount))
                            .interpolationMethod(.stepEnd)
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(minHeight: 100)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .onAppear(perform: reload)
    }

    private func reload() {
        rows = model.dailyHealth()
    }

    private func date(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

// MARK: - History

private enum HistorySpan: String, CaseIterable, Identifiable {
    case day, week, month
    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .day: 24 * 3600
        case .week: 7 * 24 * 3600
        case .month: 30 * 24 * 3600
        }
    }

    var title: String {
        switch self {
        case .day: String(localized: "24 hours")
        case .week: String(localized: "7 days")
        case .month: String(localized: "30 days")
        }
    }
}

private struct HistoryTab: View {
    let model: AppModel
    @State private var span = HistorySpan.day
    @State private var charge: [ChartPoint] = []
    @State private var temperature: [ChartPoint] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Span", selection: $span) {
                ForEach(HistorySpan.allCases) { Text(verbatim: $0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)

            if charge.isEmpty {
                ContentUnavailableView(
                    "No samples yet", systemImage: "chart.xyaxis.line",
                    description: Text("BatteryKeeper records a sample every minute while the Mac is awake."))
            } else {
                Text("Charge").font(.headline)
                Chart(charge, id: \.date) { point in
                    AreaMark(x: .value("Time", point.date), y: .value("Charge", point.value))
                        .foregroundStyle(.green.opacity(0.25))
                    LineMark(x: .value("Time", point.date), y: .value("Charge", point.value))
                        .foregroundStyle(.green)
                }
                .chartYScale(domain: 0...100)
                .chartYAxisLabel("%")
                .frame(minHeight: 150)
                Text("Temperature").font(.headline)
                Chart(temperature, id: \.date) { point in
                    LineMark(x: .value("Time", point.date), y: .value("Temperature", point.value))
                        .foregroundStyle(.orange)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxisLabel("°C")
                .frame(minHeight: 110)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .onAppear(perform: reload)
        .onChange(of: span) { reload() }
        .onChange(of: model.statsRevision) { reload() }
    }

    private func reload() {
        let samples = model.samples(since: Date().addingTimeInterval(-span.seconds))
        let bucket = Downsample.bucket(for: span.seconds, points: 600, minimum: 60)
        charge = Downsample.average(samples, bucket: bucket, date: \.date, value: { Double($0.percent) })
        temperature = Downsample.average(samples, bucket: bucket, date: \.date, value: \.temperature)
    }
}

// MARK: - Power

private struct PowerSeries: Identifiable {
    var id: String { name }
    let name: String
    let color: Color
    let points: [ChartPoint]
}

private struct PowerTab: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PowerFlowView(snapshot: model.snapshot)
                .padding(10)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            Text("Last 15 minutes").font(.headline)
            Chart {
                ForEach(series) { line in
                    ForEach(line.points, id: \.date) { point in
                        LineMark(x: .value("Time", point.date), y: .value("Watts", point.value))
                            .foregroundStyle(by: .value("Series", line.name))
                    }
                }
                RuleMark(y: .value("Zero", 0)).foregroundStyle(.secondary.opacity(0.4))
            }
            .chartForegroundStyleScale(domain: series.map(\.name), range: series.map(\.color))
            .chartYAxisLabel("W")
            .frame(minHeight: 220)
            Spacer(minLength: 0)
        }
        .padding()
    }

    private var series: [PowerSeries] {
        let recent = model.recent
        return [
            PowerSeries(
                name: String(localized: "Adapter"), color: .blue,
                points: recent.compactMap { s in s.systemPowerIn.flatMap { s.isPluggedIn ? ChartPoint(date: s.date, value: $0) : nil } }),
            PowerSeries(
                name: String(localized: "System"), color: .purple,
                points: recent.compactMap { s in s.systemLoad.map { ChartPoint(date: s.date, value: $0) } }),
            PowerSeries(
                name: String(localized: "Battery"), color: .green,
                points: recent.map { ChartPoint(date: $0.date, value: $0.batteryPower) }),
        ]
    }
}

// MARK: - Events

private struct EventsTab: View {
    let model: AppModel
    @State private var events: [BatteryEvent] = []

    var body: some View {
        Group {
            if events.isEmpty {
                ContentUnavailableView("No events yet", systemImage: "list.bullet")
            } else {
                Table(events.indices.map { IndexedEvent(index: $0, event: events[$0]) }) {
                    TableColumn("Time") { row in
                        Text(verbatim: row.event.date.formatted(date: .abbreviated, time: .standard)).monospacedDigit()
                    }
                    .width(min: 140, ideal: 170, max: 220)
                    TableColumn("Event") { row in
                        Text(verbatim: Texts.event(row.event))
                    }
                }
            }
        }
        .padding()
        .onAppear(perform: reload)
        .onChange(of: model.statsRevision) { reload() }
    }

    private func reload() {
        events = model.events()
    }
}

private struct IndexedEvent: Identifiable {
    let index: Int
    let event: BatteryEvent
    var id: Int { index }
}
