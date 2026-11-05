import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// SQLite 連線僅由序列佇列使用；UI 不執行編碼或磁碟寫入。
final class LibraryDatabase: @unchecked Sendable {
    enum Failure: LocalizedError {
        case database, newerVersion, damaged
        var errorDescription: String? {
            switch self {
            case .database: return "資料庫讀寫失敗，請確認儲存空間並保留原始資料。"
            case .newerVersion: return "此資料庫來自較新版 App，已停止寫入以保護資料。"
            case .damaged: return "資料庫內容不完整，已保留原始檔案。"
            }
        }
    }
    private let worker = DispatchQueue(label: "app.chai.music.database", qos: .utility)
    private var handle: OpaquePointer?
    private var pending: LibrarySnapshot?
    private var scheduled = false
    private var callbacks: [(Error?) -> Void] = []
    private var cachedRows: [String: [String: Data]] = [:]
    private var cachedOrder: [String: [String: Int]] = [:]
    private var priorTracks: [UUID: Track] = [:]
    private var priorPlaylists: [UUID: Playlist] = [:]
    private var priorEvents: [UUID: ListeningEvent] = [:]
    private var lastQueue: Data?
    private var lastError: Error?
    let url: URL
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(root: URL) throws {
        url = root.appendingPathComponent("library.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do { try worker.sync {
            guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw Failure.database }
            sqlite3_busy_timeout(handle, 5_000)
            let version = try integer("PRAGMA user_version")
            guard version <= 2 else { throw Failure.newerVersion }
            guard try string("PRAGMA quick_check") == "ok" else { throw Failure.damaged }
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=NORMAL")
            try execute("CREATE TABLE IF NOT EXISTS tracks (id TEXT PRIMARY KEY, ordinal INTEGER NOT NULL, payload BLOB NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS playlists (id TEXT PRIMARY KEY, ordinal INTEGER NOT NULL, payload BLOB NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS events (id TEXT PRIMARY KEY, ordinal INTEGER NOT NULL, payload BLOB NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, payload BLOB NOT NULL)")
            try execute("PRAGMA user_version=2")
            if try integer("SELECT COUNT(*) FROM state WHERE key='queue'") == 0 {
                let old = root.appendingPathComponent("library.json")
                if FileManager.default.fileExists(atPath: old.path) {
                    let data = try Data(contentsOf: old)
                    let snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: data)
                    guard snapshot.version == 1 || snapshot.version == 2 else { throw Failure.newerVersion }
                    try write(snapshot)
                    // 舊 JSON 保留原位作遷移回復來源，永不由新版本覆寫。
                } else { try write(LibrarySnapshot()) }
            }
        } } catch {
            if let handle { sqlite3_close_v2(handle); self.handle = nil }
            throw error
        }
    }
    deinit { if let handle { sqlite3_close_v2(handle) } }

    func load() throws -> LibrarySnapshot {
        try worker.sync {
            let tracks: [Track] = try readRows("tracks")
            let playlists: [Playlist] = try readRows("playlists")
            let events: [ListeningEvent] = try readRows("events")
            let queueData = try stateData("queue")
            let queue = try queueData.map { try JSONDecoder().decode(QueueState.self, from: $0) } ?? QueueState()
            guard Set(tracks.map(\.id)).count == tracks.count,
                  Set(playlists.map(\.id)).count == playlists.count,
                  Set(events.map(\.id)).count == events.count else { throw Failure.damaged }
            lastQueue = queueData
            priorTracks = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
            priorPlaylists = Dictionary(uniqueKeysWithValues: playlists.map { ($0.id, $0) })
            priorEvents = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
            return LibrarySnapshot(version: 2, tracks: tracks, playlists: playlists, queue: queue, events: events)
        }
    }
    func schedule(_ snapshot: LibrarySnapshot, completion: @escaping (Error?) -> Void) {
        worker.async { [self] in
            pending = snapshot
            callbacks.append(completion)
            guard !scheduled else { return }
            scheduled = true
            worker.asyncAfter(deadline: .now() + 0.75) { [self] in drain() }
        }
    }
    func flush() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            worker.async { [self] in
                drain()
                if let error = lastError { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
    func replace(with snapshot: LibrarySnapshot) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            worker.async { [self] in
                drain()
                do {
                    try write(snapshot)
                    lastError = nil
                    continuation.resume()
                } catch { lastError = error; continuation.resume(throwing: error) }
            }
        }
    }
    func backup(to destination: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            worker.async { [self] in
                drain()
                var target: OpaquePointer?
                do {
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    guard sqlite3_open(destination.path, &target) == SQLITE_OK else { throw Failure.database }
                    defer { sqlite3_close_v2(target) }
                    guard let transfer = sqlite3_backup_init(target, "main", handle, "main") else { throw Failure.database }
                    let step = sqlite3_backup_step(transfer, -1)
                    let finish = sqlite3_backup_finish(transfer)
                    guard step == SQLITE_DONE, finish == SQLITE_OK else { throw Failure.database }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func drain() {
        scheduled = false
        guard let snapshot = pending else { return }
        pending = nil
        let waiting = callbacks; callbacks.removeAll(keepingCapacity: true)
        do { try write(snapshot); lastError = nil; waiting.forEach { $0(nil) } }
        catch { lastError = error; waiting.forEach { $0(error) } }
    }
    private func write(_ snapshot: LibrarySnapshot) throws {
        guard Set(snapshot.tracks.map(\.id)).count == snapshot.tracks.count,
              Set(snapshot.playlists.map(\.id)).count == snapshot.playlists.count,
              Set(snapshot.events.map(\.id)).count == snapshot.events.count else { throw Failure.damaged }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let tracks = try snapshot.tracks.map { item -> (String, Data) in
            let cached = priorTracks[item.id] == item ? cachedRows["tracks"]?[item.id.uuidString] : nil
            return (item.id.uuidString, try cached ?? encoder.encode(item))
        }
        let playlists = try snapshot.playlists.map { item -> (String, Data) in
            let cached = priorPlaylists[item.id] == item ? cachedRows["playlists"]?[item.id.uuidString] : nil
            return (item.id.uuidString, try cached ?? encoder.encode(item))
        }
        let events = try snapshot.events.map { item -> (String, Data) in
            let cached = priorEvents[item.id].map { sameEvent($0, item) } == true ? cachedRows["events"]?[item.id.uuidString] : nil
            return (item.id.uuidString, try cached ?? encoder.encode(item))
        }
        let queue = try encoder.encode(snapshot.queue)
        try execute("BEGIN IMMEDIATE")
        do {
            try updateRows("tracks", rows: tracks)
            try updateRows("playlists", rows: playlists)
            try updateRows("events", rows: events)
            if queue != lastQueue {
                let statement = try prepare("INSERT INTO state(key,payload) VALUES('queue',?) ON CONFLICT(key) DO UPDATE SET payload=excluded.payload")
                defer { sqlite3_finalize(statement) }
                try bind(queue, to: statement, index: 1)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.database }
            }
            try execute("COMMIT")
            cachedRows["tracks"] = Dictionary(uniqueKeysWithValues: tracks)
            cachedRows["playlists"] = Dictionary(uniqueKeysWithValues: playlists)
            cachedRows["events"] = Dictionary(uniqueKeysWithValues: events)
            lastQueue = queue
            for (table, rows) in [("tracks", tracks), ("playlists", playlists), ("events", events)] {
                cachedOrder[table] = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.0, $0.offset) })
            }
            priorTracks = Dictionary(uniqueKeysWithValues: snapshot.tracks.map { ($0.id, $0) })
            priorPlaylists = Dictionary(uniqueKeysWithValues: snapshot.playlists.map { ($0.id, $0) })
            priorEvents = Dictionary(uniqueKeysWithValues: snapshot.events.map { ($0.id, $0) })
        } catch { try? execute("ROLLBACK"); throw error }
    }
    private func updateRows(_ table: String, rows: [(String, Data)]) throws {
        let prior = cachedRows[table] ?? [:]
        let ids = Set(rows.map(\.0))
        let remove = try prepare("DELETE FROM \(table) WHERE id=?")
        defer { sqlite3_finalize(remove) }
        for id in prior.keys where !ids.contains(id) {
            sqlite3_reset(remove); sqlite3_clear_bindings(remove)
            sqlite3_bind_text(remove, 1, id, -1, transient)
            guard sqlite3_step(remove) == SQLITE_DONE else { throw Failure.database }
        }
        let upsert = try prepare("INSERT INTO \(table)(id,ordinal,payload) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET ordinal=excluded.ordinal,payload=excluded.payload")
        defer { sqlite3_finalize(upsert) }
        // 順序是資料的一部分；僅在內容或順序異動時寫入。
        for (index, row) in rows.enumerated() {
            if prior[row.0] == row.1, cachedOrder[table]?[row.0] == index { continue }
            sqlite3_reset(upsert); sqlite3_clear_bindings(upsert)
            sqlite3_bind_text(upsert, 1, row.0, -1, transient)
            sqlite3_bind_int64(upsert, 2, sqlite3_int64(index))
            try bind(row.1, to: upsert, index: 3)
            guard sqlite3_step(upsert) == SQLITE_DONE else { throw Failure.database }
        }
    }
    private func sameEvent(_ lhs: ListeningEvent, _ rhs: ListeningEvent) -> Bool {
        lhs.id == rhs.id && lhs.trackID == rhs.trackID && lhs.playlistID == rhs.playlistID && lhs.date == rhs.date &&
        lhs.seconds == rhs.seconds && lhs.duration == rhs.duration && lhs.completed == rhs.completed &&
        lhs.skipped == rhs.skipped && lhs.manual == rhs.manual && lhs.replay == rhs.replay
    }
    private func readRows<T: Decodable>(_ table: String) throws -> [T] {
        let statement = try prepare("SELECT id,payload FROM \(table) ORDER BY ordinal")
        defer { sqlite3_finalize(statement) }
        var result: [T] = []; var cache: [String: Data] = [:]
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW, let rawID = sqlite3_column_text(statement, 0) else { throw Failure.damaged }
            let data = columnData(statement, 1)
            result.append(try JSONDecoder().decode(T.self, from: data))
            cache[String(cString: rawID)] = data
        }
        cachedRows[table] = cache
        let ids = try prepare("SELECT id FROM \(table) ORDER BY ordinal")
        defer { sqlite3_finalize(ids) }
        var order: [String: Int] = [:]
        while sqlite3_step(ids) == SQLITE_ROW {
            guard let value = sqlite3_column_text(ids, 0) else { throw Failure.damaged }
            order[String(cString: value)] = order.count
        }
        cachedOrder[table] = order
        return result
    }
    private func stateData(_ key: String) throws -> Data? {
        let statement = try prepare("SELECT payload FROM state WHERE key=?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, transient)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw Failure.database }
        return columnData(statement, 0)
    }
    private func columnData(_ statement: OpaquePointer?, _ column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
    private func bind(_ data: Data, to statement: OpaquePointer?, index: Int32) throws {
        let result = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), transient) }
        guard result == SQLITE_OK else { throw Failure.database }
    }
    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw Failure.database }
        return statement
    }
    private func execute(_ sql: String) throws { guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.database } }
    private func integer(_ sql: String) throws -> Int {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw Failure.database }
        return Int(sqlite3_column_int64(statement, 0))
    }
    private func string(_ sql: String) throws -> String {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { throw Failure.database }
        return String(cString: value)
    }
}
