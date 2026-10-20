import AppKit
import BatteryKeeperCore
import BatteryKeeperSystem
import Observation
import os

/// The app's state and the loop that drives it: reads the battery every few seconds, records statistics,
/// runs the calibration cycle and tells the menu bar item to redraw.
@MainActor
@Observable
final class AppModel {
    /// How often the battery is read, seconds.
    static let refreshInterval: TimeInterval = 5
    /// How often a sample is stored, seconds.
    static let sampleInterval: TimeInterval = 60
    /// How often the system charge limit is read back, seconds.
    static let limitInterval: TimeInterval = 30
    /// How often the adapter lease is renewed while the adapter is cut, seconds.
    static let leaseRenewal: TimeInterval = 30
    /// Samples older than this are deleted.
    static let sampleRetention: TimeInterval = 30 * 24 * 3600
    /// Snapshots kept in memory for the live power chart.
    static let recentSpan: TimeInterval = 15 * 60

    private(set) var snapshot: BatterySnapshot?
    private(set) var recent: [BatterySnapshot] = []
    private(set) var limitState = ChargeLimitState.unsupported
    private(set) var cycle: CycleState?
    private(set) var helperStatus = HelperStatus.notRegistered
    /// The helper answered the last call; nil before the first.
    private(set) var helperReachable: Bool?
    /// The helper has cut the adapter at this app's request.
    private(set) var adapterCut = false
    private(set) var lastCycleEndedAt: Date
    private(set) var lastError: String?
    /// Bumped when stored statistics change, so that open charts reload.
    private(set) var statsRevision = 0
    var launchAtLogin: Bool { loginItem.isEnabled }

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            defaults.set(settings.encoded(), forKey: Keys.settings)
            onChange?()
        }
    }

    /// Called whenever the menu bar item may need to redraw.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let reader = BatteryReader()
    @ObservationIgnored private let chargeLimit = ChargeLimitController()
    @ObservationIgnored private let helper = HelperClient()
    @ObservationIgnored private let sleepAssertion = SleepAssertion()
    @ObservationIgnored private let loginItem = LoginItem()
    @ObservationIgnored private let store: StatsStore?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let log = Logger(subsystem: "io.damao.batterykeeper", category: "model")
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var powerObserver: PowerSourceObserver?
    @ObservationIgnored private var lastSampleAt: Date?
    @ObservationIgnored private var lastLimitReadAt: Date?
    @ObservationIgnored private var lastHealthDay: String?
    @ObservationIgnored private var lastLeaseRequestAt: Date?
    @ObservationIgnored private var adapterRequestInFlight = false
    /// The adapter is cut or about to be: set before the request goes out, because the system reports the
    /// adapter as disconnected the moment the helper cuts it, before the reply arrives.
    @ObservationIgnored private var adapterCutIntended = false
    @ObservationIgnored private var lastLoggedProblem: String?

    private enum Keys {
        static let settings = "settings"
        static let cycleState = "cycleState"
        static let lastCycleEndedAt = "lastCycleEndedAt"
        static let loginItemSetUp = "loginItemSetUp"
    }

    init() {
        settings = AppSettings.decode(UserDefaults.standard.data(forKey: Keys.settings))
        if let data = UserDefaults.standard.data(forKey: Keys.cycleState) {
            cycle = try? JSONDecoder().decode(CycleState.self, from: data)
        }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Keys.lastCycleEndedAt) != nil {
            lastCycleEndedAt = Date(timeIntervalSince1970: defaults.double(forKey: Keys.lastCycleEndedAt))
        } else {
            let reference = Self.initialScheduleReference()
            defaults.set(reference.timeIntervalSince1970, forKey: Keys.lastCycleEndedAt)
            lastCycleEndedAt = reference
        }
        var storeError: String?
        do {
            store = try StatsStore(url: StatsStore.defaultURL())
        } catch {
            store = nil
            storeError = error.description
        }
        if let storeError {
            lastError = String(localized: "Statistics are unavailable: \(storeError)")
        }
    }

    /// The first schedule counts from AlDente's last calibration when it is installed, else from now.
    private static func initialScheduleReference() -> Date {
        let now = Date()
        let aldente = UserDefaults(suiteName: "com.apphousekitchen.aldente-pro")?.double(forKey: "lastCalibrationTimestamp") ?? 0
        let date = Date(timeIntervalSince1970: aldente)
        if aldente > 1_600_000_000, date < now { return date }
        return now
    }

    // MARK: - Lifecycle

    func start() {
        record(BatteryEvent(date: Date(), kind: .appLaunched))
        setUpLoginItemOnce()
        try? store?.pruneSamples(before: Date().addingTimeInterval(-Self.sampleRetention))
        helperStatus = helper.status
        readLimit()
        checkHelper()
        if let state = cycle, Date().timeIntervalSince(state.startedAt) > CalibrationCycle.maximumDuration {
            endCycle(.cycleExpired)
        }
        helper.onConnectionLost = { [weak self] in
            guard let self, self.adapterCut else { return }
            // The helper restored the adapter when the connection broke; the next refresh cuts it again.
            self.adapterCut = false
            self.lastLeaseRequestAt = nil
        }
        let observer = PowerSourceObserver { [weak self] in self?.refresh() }
        observer.start()
        powerObserver = observer
        // The helper restores the adapter before the Mac sleeps; after waking, cut it again right away
        // instead of at the next lease renewal.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.adapterCut = false
                self.adapterCutIntended = false
                self.lastLeaseRequestAt = nil
                self.refresh()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    /// Restores the adapter before the app quits. The helper would restore it when the lease runs out anyway.
    func prepareForQuit() async {
        sleepAssertion.set(false, reason: "")
        guard adapterCut else { return }
        try? await helper.setAdapterEnabled(true)
        adapterCut = false
    }

    // MARK: - Refresh

    func refresh() {
        let now = Date()
        guard var new = reader.read(now: now) else {
            snapshot = nil
            onChange?()
            return
        }
        // While the helper has cut it, the adapter reads as disconnected; it is still plugged in.
        if adapterCut || adapterCutIntended {
            new.isPluggedIn = true
        }
        let events = EventDetector.events(from: snapshot, to: new)
        events.forEach(record)
        snapshot = new
        recent.append(new)
        if let first = recent.first, now.timeIntervalSince(first.date) > Self.recentSpan {
            recent.removeAll { now.timeIntervalSince($0.date) > Self.recentSpan }
        }
        if lastLimitReadAt.map({ now.timeIntervalSince($0) >= Self.limitInterval }) ?? true {
            readLimit()
        }
        helperStatus = helper.status
        recordSample(new, force: !events.isEmpty)
        tickCycle(new, now: now)
        onChange?()
    }

    private func readLimit() {
        limitState = chargeLimit.read()
        lastLimitReadAt = Date()
    }

    private func recordSample(_ snapshot: BatterySnapshot, force: Bool) {
        guard let store else { return }
        if !force, let last = lastSampleAt, snapshot.date.timeIntervalSince(last) < Self.sampleInterval { return }
        lastSampleAt = snapshot.date
        do {
            try store.insert(StoredSample(snapshot: snapshot, limit: limitState.isSupported ? limitState.limit : nil))
            let day = DailyHealth.dayKey(for: snapshot.date, calendar: .current)
            if day != lastHealthDay, snapshot.designCapacity > 0 {
                try store.upsert(DailyHealth(day: day, snapshot: snapshot))
                lastHealthDay = day
            }
            statsRevision += 1
        } catch {
            log.error("recording a sample failed: \(error.description, privacy: .public)")
        }
    }

    private func record(_ event: BatteryEvent) {
        do {
            try store?.insert(event)
            statsRevision += 1
        } catch {
            log.error("recording an event failed: \(error.description, privacy: .public)")
        }
    }

    // MARK: - Charge limit

    var limitChangeAllowed: Bool { limitState.isSupported }

    /// Sets the daily limit. During a cycle it only changes the limit the cycle restores.
    func setLimit(_ limit: Int) {
        if var state = cycle {
            state.restoreLimit = limit
            cycle = state
            saveCycle()
            record(BatteryEvent(date: Date(), kind: .limitChanged, detail: "\(limit)"))
            return
        }
        do {
            try chargeLimit.setLimit(limit)
            lastError = nil
            record(BatteryEvent(date: Date(), kind: .limitChanged, detail: "\(limit)"))
        } catch {
            lastError = String(localized: "Could not set the charge limit: \(error.description)")
        }
        readLimit()
        onChange?()
    }

    /// The limit the popover shows: the one the cycle will restore while a cycle runs.
    var displayedLimit: Int { cycle?.restoreLimit ?? limitState.limit }

    func chargeToFullNow() {
        do {
            try chargeLimit.chargeToFullNow()
            lastError = nil
            record(BatteryEvent(date: Date(), kind: .chargeToFullNow))
        } catch {
            lastError = String(localized: "Could not start charging to full: \(error.description)")
        }
        readLimit()
    }

    // MARK: - Calibration cycle

    var canStartCycle: Bool {
        cycle == nil && helperStatus == .enabled && limitState.isSupported && snapshot != nil
    }

    var nextScheduledCycle: Date? {
        guard settings.cycle.isScheduled else { return nil }
        return CycleSchedule.nextStart(after: lastCycleEndedAt, settings: settings.cycle, calendar: .current)
    }

    func startCycle() {
        startCycle(manual: true)
    }

    func cancelCycle() {
        endCycle(.cycleCancelled)
    }

    private func startCycle(manual: Bool) {
        guard cycle == nil, let snapshot else { return }
        guard helperStatus == .enabled else {
            lastError = String(localized: "The helper must be installed and allowed before a cycle can discharge.")
            return
        }
        let restore = limitState.isSupported ? limitState.limit : 100
        do {
            try chargeLimit.disable()
        } catch {
            lastError = String(localized: "Could not lift the charge limit: \(error.description)")
            return
        }
        lastError = nil
        var state = CalibrationCycle.start(at: Date(), restoreLimit: restore, settings: settings.cycle, manual: manual)
        #if DEBUG
        state = Self.applyingTestOverrides(to: state)
        #endif
        cycle = state
        saveCycle()
        record(BatteryEvent(date: Date(), kind: .cycleStarted, detail: manual ? "manual" : "scheduled"))
        readLimit()
        tickCycle(snapshot, now: Date())
    }

    #if DEBUG
    /// Shortened test cycles for Debug builds, from launch arguments or defaults:
    /// `-testCycleFull 80 -testCycleFloor 77 -testCycleHoldMinutes 1 -testCyclePhase dischargeToFloor`.
    private static func applyingTestOverrides(to state: CycleState) -> CycleState {
        var state = state
        // Launch arguments arrive as strings, `defaults write -int` as numbers; `string(forKey:)` reads both.
        func int(_ key: String) -> Int? { UserDefaults.standard.string(forKey: key).flatMap { Int($0) } }
        if let full = int("testCycleFull"), (1...100).contains(full) {
            state.fullPercent = full
        }
        if let floor = int("testCycleFloor"), (AdapterLease.hardFloorPercent + 1...99).contains(floor) {
            state.floorPercent = floor
        }
        if let hold = int("testCycleHoldMinutes"), hold >= 0 {
            state.holdMinutes = hold
        }
        let defaults = UserDefaults.standard
        if let phase = defaults.string(forKey: "testCyclePhase").flatMap(CyclePhase.init(rawValue:)) {
            state.phase = phase
        }
        return state
    }
    #endif

    private func tickCycle(_ snapshot: BatterySnapshot, now: Date) {
        guard let state = cycle else {
            if helperStatus == .enabled, limitState.isSupported,
                CycleSchedule.shouldStart(
                    now: now, reference: lastCycleEndedAt, settings: settings.cycle, snapshot: snapshot, calendar: .current)
            {
                startCycle(manual: false)
            } else if adapterCut {
                requestAdapter(enabled: true)
            }
            return
        }
        switch CalibrationCycle.advance(state, snapshot: snapshot, now: now) {
        case .running(let next):
            if next.phase != state.phase {
                record(BatteryEvent(date: now, kind: .cyclePhase, detail: next.phase.rawValue))
            }
            if next != state {
                cycle = next
                saveCycle()
            }
            apply(CalibrationCycle.directive(for: next.phase))
        case .finished:
            endCycle(.cycleFinished)
        case .expired:
            endCycle(.cycleExpired)
        }
    }

    private func apply(_ directive: CycleDirective) {
        sleepAssertion.set(directive.preventSleep, reason: "BatteryKeeper calibration cycle")
        requestAdapter(enabled: directive.adapterEnabled)
    }

    private func endCycle(_ kind: BatteryEventKind) {
        guard let state = cycle else { return }
        cycle = nil
        saveCycle()
        lastCycleEndedAt = Date()
        defaults.set(lastCycleEndedAt.timeIntervalSince1970, forKey: Keys.lastCycleEndedAt)
        sleepAssertion.set(false, reason: "")
        requestAdapter(enabled: true, force: true)
        do {
            try chargeLimit.setLimit(state.restoreLimit)
        } catch {
            lastError = String(localized: "Could not restore the charge limit: \(error.description)")
        }
        record(BatteryEvent(date: Date(), kind: kind))
        readLimit()
        onChange?()
    }

    private func saveCycle() {
        if let cycle, let data = try? JSONEncoder().encode(cycle) {
            defaults.set(data, forKey: Keys.cycleState)
        } else {
            defaults.removeObject(forKey: Keys.cycleState)
        }
    }

    /// Asks the helper to cut (renewing the lease every ``leaseRenewal`` seconds) or restore the adapter.
    private func requestAdapter(enabled: Bool, force: Bool = false) {
        let now = Date()
        if enabled {
            guard adapterCut || force else { return }
        } else if adapterCut, let last = lastLeaseRequestAt, now.timeIntervalSince(last) < Self.leaseRenewal {
            return
        }
        guard !adapterRequestInFlight || force else { return }
        adapterRequestInFlight = true
        adapterCutIntended = !enabled
        Task {
            defer { adapterRequestInFlight = false }
            do {
                try await helper.setAdapterEnabled(enabled)
                adapterCut = !enabled
                lastLeaseRequestAt = enabled ? nil : now
                helperReachable = true
                lastLoggedProblem = nil
            } catch {
                helperReachable = false
                // A failed restore still leaves the helper to restore the adapter when the lease runs out.
                if enabled { adapterCut = false }
                adapterCutIntended = adapterCut
                reportHelperProblem(String(describing: error))
            }
            onChange?()
        }
    }

    private func reportHelperProblem(_ message: String) {
        lastError = String(localized: "Helper: \(message)")
        guard message != lastLoggedProblem else { return }
        lastLoggedProblem = message
        record(BatteryEvent(date: Date(), kind: .helperProblem, detail: message))
    }

    // MARK: - Helper

    func installHelper() {
        do {
            try helper.register()
            lastError = nil
        } catch {
            lastError = String(localized: "Could not install the helper: \(error.description)")
        }
        helperStatus = helper.status
        if helperStatus == .requiresApproval {
            helper.openSystemSettings()
        }
        checkHelper()
    }

    func openLoginItemsSettings() {
        helper.openSystemSettings()
    }

    func checkHelper() {
        helperStatus = helper.status
        guard helperStatus == .enabled else {
            helperReachable = nil
            return
        }
        Task {
            do {
                let version = try await helper.protocolVersion()
                helperReachable = version == HelperConstants.protocolVersion
                if version != HelperConstants.protocolVersion {
                    lastError = String(localized: "The installed helper is outdated. Reinstall it from Settings.")
                }
            } catch {
                helperReachable = false
                reportHelperProblem(String(describing: error))
            }
        }
    }

    func uninstallHelper() {
        Task {
            if adapterCut { try? await helper.setAdapterEnabled(true) }
            do {
                try await helper.unregister()
            } catch {
                lastError = String(localized: "Could not remove the helper: \(String(describing: error))")
            }
            helperStatus = helper.status
            helperReachable = nil
        }
    }

    // MARK: - Login item

    /// The first launch from /Applications switches launch at login on; after that it is the user's choice.
    private func setUpLoginItemOnce() {
        guard !defaults.bool(forKey: Keys.loginItemSetUp), Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        defaults.set(true, forKey: Keys.loginItemSetUp)
        setLaunchAtLogin(true)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try loginItem.setEnabled(enabled)
        } catch {
            lastError = String(localized: "Could not change the login item: \(error.description)")
        }
    }

    // MARK: - Statistics

    func samples(since: Date) -> [StoredSample] {
        (try? store?.samples(since: since)) ?? []
    }

    func dailyHealth() -> [DailyHealth] {
        (try? store?.dailyHealth()) ?? []
    }

    func events(limit: Int = 300) -> [BatteryEvent] {
        (try? store?.events(limit: limit)) ?? []
    }

    func clearError() {
        lastError = nil
    }
}
