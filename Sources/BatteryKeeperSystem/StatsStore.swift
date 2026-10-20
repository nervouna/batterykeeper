import BatteryKeeperCore
import Foundation
import SQLite3

public struct StatsStoreError: Error, CustomStringConvertible, Sendable {
    public var description: String
}

/// The statistics database: samples, one health row a day, and the event log. Schema changes are
/// forward-only: `user_version` is the schema version, and a database of a newer version is refused.
public final class StatsStore: @unchecked Sendable {
    public static let schemaVersion: Int32 = 1

    private var db: OpaquePointer?
    private let lock = NSLock()

    /// The default location: `~/Library/Application Support/BatteryKeeper/stats.sqlite`.
    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("BatteryKeeper", isDirectory: true).appendingPathComponent("stats.sqlite")
    }

    public init(url: URL) throws(StatsStoreError) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw StatsStoreError(description: error.localizedDescription)
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
            == SQLITE_OK
        else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(url.path)"
            sqlite3_close(handle)
            throw StatsStoreError(description: message)
        }
        db = handle
        try migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    private func migrate() throws(StatsStoreError) {
        let version = try queryInt("PRAGMA user_version") ?? 0
        if version > Self.schemaVersion {
            throw StatsStoreError(description: "statistics database version \(version) is newer than this app")
        }
        if version == 0 {
            try exec(
                """
                PRAGMA journal_mode = WAL;
                CREATE TABLE samples (
                    time REAL NOT NULL,
                    percent INTEGER NOT NULL,
                    temperature REAL,
                    voltage REAL NOT NULL,
                    amperage REAL NOT NULL,
                    system_load REAL,
                    system_power_in REAL,
                    adapter_watts INTEGER,
                    plugged_in INTEGER NOT NULL,
                    charging INTEGER NOT NULL,
                    charge_limit INTEGER
                );
                CREATE INDEX samples_time ON samples(time);
                CREATE TABLE daily_health (
                    day TEXT PRIMARY KEY,
                    full_charge_capacity INTEGER NOT NULL,
                    nominal_charge_capacity INTEGER NOT NULL,
                    design_capacity INTEGER NOT NULL,
                    cycle_count INTEGER NOT NULL
                );
                CREATE TABLE events (
                    time REAL NOT NULL,
                    kind TEXT NOT NULL,
                    detail TEXT NOT NULL
                );
                CREATE INDEX events_time ON events(time);
                PRAGMA user_version = 1;
                """)
        }
    }

    // MARK: - Samples

    public func insert(_ sample: StoredSample) throws(StatsStoreError) {
        try run(
            "INSERT INTO samples VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [
                .real(sample.date.timeIntervalSince1970), .int(sample.percent), .optionalReal(sample.temperature),
                .real(sample.voltage), .real(sample.amperage), .optionalReal(sample.systemLoad),
                .optionalReal(sample.systemPowerIn), .optionalInt(sample.adapterWatts), .int(sample.isPluggedIn ? 1 : 0),
                .int(sample.isCharging ? 1 : 0), .optionalInt(sample.limit),
            ])
    }

    public func samples(since: Date) throws(StatsStoreError) -> [StoredSample] {
        try query("SELECT * FROM samples WHERE time >= ? ORDER BY time", [.real(since.timeIntervalSince1970)]) { row in
            StoredSample(
                date: Date(timeIntervalSince1970: row.double(0)), percent: row.int(1), temperature: row.optionalDouble(2),
                voltage: row.double(3), amperage: row.double(4), systemLoad: row.optionalDouble(5),
                systemPowerIn: row.optionalDouble(6), adapterWatts: row.optionalInt(7), isPluggedIn: row.int(8) != 0,
                isCharging: row.int(9) != 0, limit: row.optionalInt(10))
        }
    }

    public func pruneSamples(before date: Date) throws(StatsStoreError) {
        try run("DELETE FROM samples WHERE time < ?", [.real(date.timeIntervalSince1970)])
    }

    // MARK: - Health

    public func upsert(_ health: DailyHealth) throws(StatsStoreError) {
        try run(
            "INSERT OR REPLACE INTO daily_health VALUES (?, ?, ?, ?, ?)",
            [
                .text(health.day), .int(health.fullChargeCapacity), .int(health.nominalChargeCapacity),
                .int(health.designCapacity), .int(health.cycleCount),
            ])
    }

    public func dailyHealth() throws(StatsStoreError) -> [DailyHealth] {
        try query("SELECT * FROM daily_health ORDER BY day", []) { row in
            DailyHealth(
                day: row.text(0), fullChargeCapacity: row.int(1), nominalChargeCapacity: row.int(2),
                designCapacity: row.int(3), cycleCount: row.int(4))
        }
    }

    // MARK: - Events

    public func insert(_ event: BatteryEvent) throws(StatsStoreError) {
        try run(
            "INSERT INTO events VALUES (?, ?, ?)",
            [.real(event.date.timeIntervalSince1970), .text(event.kind.rawValue), .text(event.detail)])
    }

    /// The most recent events, newest first. Events of kinds this version does not know are left out.
    public func events(limit: Int) throws(StatsStoreError) -> [BatteryEvent] {
        try query("SELECT * FROM events ORDER BY time DESC LIMIT ?", [.int(limit)]) { row in
            BatteryEventKind(rawValue: row.text(1)).map {
                BatteryEvent(date: Date(timeIntervalSince1970: row.double(0)), kind: $0, detail: row.text(2))
            }
        }.compactMap { $0 }
    }

    // MARK: - SQLite plumbing

    enum Value {
        case int(Int)
        case real(Double)
        case text(String)
        case optionalInt(Int?)
        case optionalReal(Double?)
    }

    struct Row {
        let statement: OpaquePointer
        func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(statement, i)) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(statement, i) }
        func text(_ i: Int32) -> String { sqlite3_column_text(statement, i).map { String(cString: $0) } ?? "" }
        func isNull(_ i: Int32) -> Bool { sqlite3_column_type(statement, i) == SQLITE_NULL }
        func optionalInt(_ i: Int32) -> Int? { isNull(i) ? nil : int(i) }
        func optionalDouble(_ i: Int32) -> Double? { isNull(i) ? nil : double(i) }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func error(_ context: String) -> StatsStoreError {
        StatsStoreError(description: "\(context): \(String(cString: sqlite3_errmsg(db)))")
    }

    private func exec(_ sql: String) throws(StatsStoreError) {
        lock.lock()
        defer { lock.unlock() }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error("exec") }
    }

    private func prepare(_ sql: String, _ values: [Value]) throws(StatsStoreError) -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error("prepare") }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .int(let v): sqlite3_bind_int64(statement, index, Int64(v))
            case .real(let v): sqlite3_bind_double(statement, index, v)
            case .text(let v): sqlite3_bind_text(statement, index, v, -1, Self.transient)
            case .optionalInt(let v):
                if let v { sqlite3_bind_int64(statement, index, Int64(v)) } else { sqlite3_bind_null(statement, index) }
            case .optionalReal(let v):
                if let v { sqlite3_bind_double(statement, index, v) } else { sqlite3_bind_null(statement, index) }
            }
        }
        return statement
    }

    private func run(_ sql: String, _ values: [Value]) throws(StatsStoreError) {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error("step") }
    }

    private func query<T>(_ sql: String, _ values: [Value], _ map: (Row) -> T) throws(StatsStoreError) -> [T] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var results: [T] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw error("step") }
            results.append(map(Row(statement: statement)))
        }
        return results
    }

    private func queryInt(_ sql: String) throws(StatsStoreError) -> Int32? {
        try query(sql, []) { Int32($0.int(0)) }.first
    }
}
