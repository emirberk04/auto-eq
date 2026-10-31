import Foundation
import SQLite3

/// Per-track analysis results (CLAUDE.md §6), keyed by title / artist / duration. Stores
/// derived numbers only; never audio. Not thread-safe: use from one queue.
public final class TrackCache {
    public struct Entry: Sendable, Equatable {
        public var title: String
        public var artist: String
        public var durationSeconds: Double
        public var features: TrackFeatures
        /// Filled in Phase 5 (sidecar); nil until then.
        public var bpm: Double?
        public var styles: [String]?

        public init(title: String, artist: String, durationSeconds: Double, features: TrackFeatures,
                    bpm: Double? = nil, styles: [String]? = nil) {
            (self.title, self.artist, self.durationSeconds, self.features, self.bpm, self.styles) =
                (title, artist, durationSeconds, features, bpm, styles)
        }

        public var key: String { TrackCache.key(title: title, artist: artist, durationSeconds: durationSeconds) }
    }

    private var db: OpaquePointer?

    public static func key(title: String, artist: String, durationSeconds: Double) -> String {
        "\(title)\u{1F}\(artist)\u{1F}\(Int(durationSeconds.rounded()))"
    }

    public init(path: String) throws {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw Self.error(db) }
        try exec("""
            CREATE TABLE IF NOT EXISTS tracks (
                key TEXT PRIMARY KEY, title TEXT, artist TEXT, duration REAL,
                features BLOB NOT NULL, seconds REAL, integrated_lufs REAL, tilt REAL,
                bpm REAL, styles TEXT, updated REAL)
            """)
    }

    deinit { sqlite3_close(db) }

    public func entry(forKey key: String) -> Entry? {
        let sql = "SELECT title, artist, duration, features, bpm, styles FROM tracks WHERE key = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, Self.transient)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let blob = sqlite3_column_blob(statement, 3) else { return nil }
        let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 3)))
        guard let features = try? Self.decoder.decode(TrackFeatures.self, from: data) else { return nil }
        let styles = sqlite3_column_text(statement, 5).map { String(cString: $0) }
        return Entry(title: String(cString: sqlite3_column_text(statement, 0)),
                     artist: String(cString: sqlite3_column_text(statement, 1)),
                     durationSeconds: sqlite3_column_double(statement, 2),
                     features: features,
                     bpm: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 4),
                     styles: styles?.split(separator: "\n").map(String.init))
    }

    public func store(_ entry: Entry) throws {
        let sql = """
            INSERT OR REPLACE INTO tracks
            (key, title, artist, duration, features, seconds, integrated_lufs, tilt, bpm, styles, updated)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw Self.error(db) }
        defer { sqlite3_finalize(statement) }
        let data = try Self.encoder.encode(entry.features)
        sqlite3_bind_text(statement, 1, entry.key, -1, Self.transient)
        sqlite3_bind_text(statement, 2, entry.title, -1, Self.transient)
        sqlite3_bind_text(statement, 3, entry.artist, -1, Self.transient)
        sqlite3_bind_double(statement, 4, entry.durationSeconds)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 5, $0.baseAddress, Int32(data.count), Self.transient) }
        sqlite3_bind_double(statement, 6, entry.features.seconds)
        let lufs = entry.features.integratedLufs
        if lufs.isFinite { sqlite3_bind_double(statement, 7, lufs) } else { sqlite3_bind_null(statement, 7) }
        sqlite3_bind_double(statement, 8, entry.features.tiltDbPerOctave)
        if let bpm = entry.bpm { sqlite3_bind_double(statement, 9, bpm) } else { sqlite3_bind_null(statement, 9) }
        if let styles = entry.styles {
            sqlite3_bind_text(statement, 10, styles.joined(separator: "\n"), -1, Self.transient)
        } else {
            sqlite3_bind_null(statement, 10)
        }
        sqlite3_bind_double(statement, 11, Date().timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.error(db) }
    }

    /// Features of every track measured for at least `minSeconds`.
    public func allFeatures(minSeconds: Double) -> [TrackFeatures] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT features FROM tracks WHERE seconds >= ?", -1, &statement, nil) == SQLITE_OK
        else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, minSeconds)
        var result: [TrackFeatures] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let blob = sqlite3_column_blob(statement, 0) else { continue }
            let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 0)))
            if let f = try? Self.decoder.decode(TrackFeatures.self, from: data) { result.append(f) }
        }
        return result
    }

    public var count: Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM tracks", -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Self.error(db) }
    }

    // Loudness is −∞ for silence; JSON has no infinities.
    private static let floatStrategy = (positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: floatStrategy.positiveInfinity, negativeInfinity: floatStrategy.negativeInfinity, nan: floatStrategy.nan)
        return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: floatStrategy.positiveInfinity, negativeInfinity: floatStrategy.negativeInfinity, nan: floatStrategy.nan)
        return d
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    struct SQLiteError: Error, CustomStringConvertible { let description: String }

    private static func error(_ db: OpaquePointer?) -> SQLiteError {
        SQLiteError(description: db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite open failed")
    }
}

extension TrackFeatures {
    /// Combines two measurements of the same track, weighting the LTAS by audio seconds.
    /// Total weight is capped so an often-played track still follows a new measurement.
    public func merged(with other: TrackFeatures, maxSeconds: Double = 600) -> TrackFeatures {
        let total = seconds + other.seconds
        guard total > 0 else { return self }
        var m = other
        m.ltasPower = zip(ltasPower, other.ltasPower).map { ($0 * seconds + $1 * other.seconds) / total }
        m.seconds = min(total, maxSeconds)
        m.width = (width * seconds + other.width * other.seconds) / total
        if !other.integratedLufs.isFinite { m.integratedLufs = integratedLufs; m.plrDb = plrDb }
        return m
    }
}
