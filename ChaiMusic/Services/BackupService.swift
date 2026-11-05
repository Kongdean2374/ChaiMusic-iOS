import Foundation

/// 串流備份格式不解壓任意路徑，也不含 Keychain 或來源登入設定。
actor BackupService {
    struct Restored {
        var snapshot: LibrarySnapshot
        var installedFiles: [URL]
    }
    enum Failure: LocalizedError {
        case invalid, limit, missing, damaged
        var errorDescription: String? {
            switch self {
            case .invalid: return "不是支援的 ChaiMusic 備份，或包含不安全的路徑。"
            case .limit: return "備份超過安全限制：單檔 4 GB、總量 32 GB、資料索引 64 MB。"
            case .missing: return "備份所需的音檔或封面不存在，請先修復音樂庫。"
            case .damaged: return "備份內容校驗失敗，尚未替換音樂庫。"
            }
        }
    }
    private struct Entry: Codable { var path: String; var size: UInt64 }
    private static let magic = Data("CHAIMUSIC_BACKUP_V2\n".utf8)
    private let maxFile: UInt64 = 4 * 1024 * 1024 * 1024
    private let maxTotal: UInt64 = 32 * 1024 * 1024 * 1024
    private let chunkSize = 1024 * 1024

    nonisolated static func sanitized(_ snapshot: LibrarySnapshot) -> LibrarySnapshot {
        var safe = snapshot
        safe.version = 2
        // 遠端短效網址可能帶令牌；備份保留識別資料但不攜帶 URL 查詢或登入資訊。
        for index in safe.tracks.indices {
            safe.tracks[index].variants = safe.tracks[index].variants?.map { value in
                var copy = value
                if let url = value.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                    components.user = nil; components.password = nil; components.query = nil; components.fragment = nil
                    copy.url = components.url
                }
                return copy
            }
        }
        return safe
    }
    func export(snapshot: LibrarySnapshot, root: URL) throws -> URL {
        let safe = Self.sanitized(snapshot)
        let manifest = try JSONEncoder().encode(safe)
        guard manifest.count <= 64 * 1024 * 1024 else { throw Failure.limit }
        let paths = try referencedPaths(safe).sorted()
        var files: [(Entry, URL)] = []
        var total = UInt64(manifest.count)
        for path in paths {
            let url = root.appendingPathComponent(path)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw Failure.missing }
            let size = UInt64(max(0, values.fileSize ?? 0))
            guard size <= maxFile else { throw Failure.limit }
            total += size
            guard total <= maxTotal else { throw Failure.limit }
            files.append((Entry(path: path, size: size), url))
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("ChaiMusic-\(UUID().uuidString).chaimusic")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let writer = try FileHandle(forWritingTo: output)
        do {
            try writer.write(contentsOf: Self.magic)
            try writeUInt32(UInt32(files.count + 1), to: writer)
            try writeHeader(Entry(path: "library.json", size: UInt64(manifest.count)), to: writer)
            try writer.write(contentsOf: manifest)
            try writeUInt32(Self.crc32(manifest), to: writer)
            for (entry, url) in files {
                try Task.checkCancellation()
                try writeHeader(entry, to: writer)
                let reader = try FileHandle(forReadingFrom: url)
                var crc: UInt32 = 0xFFFFFFFF
                var written: UInt64 = 0
                do {
                    while let bytes = try reader.read(upToCount: chunkSize), !bytes.isEmpty {
                        try Task.checkCancellation()
                        written += UInt64(bytes.count)
                        guard written <= entry.size else { throw Failure.damaged }
                        crc = Self.updateCRC(crc, data: bytes)
                        try writer.write(contentsOf: bytes)
                    }
                    try reader.close()
                } catch { try? reader.close(); throw error }
                guard written == entry.size else { throw Failure.damaged }
                try writeUInt32(crc ^ 0xFFFFFFFF, to: writer)
            }
            try writer.synchronize(); try writer.close()
            return output
        } catch {
            try? writer.close(); try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    func restore(from archive: URL, into root: URL) throws -> Restored {
        #if !os(Linux)
        let scoped = archive.startAccessingSecurityScopedResource()
        defer { if scoped { archive.stopAccessingSecurityScopedResource() } }
        #endif
        let fm = FileManager.default
        let staging = root.appendingPathComponent(".restore-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let reader = try FileHandle(forReadingFrom: archive)
        defer { try? reader.close() }
        guard try readExactly(Self.magic.count, from: reader) == Self.magic else { throw Failure.invalid }
        let count = try readUInt32(from: reader)
        guard count > 0, count <= 200_001 else { throw Failure.limit }
        var names = Set<String>()
        var total: UInt64 = 0
        for _ in 0..<count {
            try Task.checkCancellation()
            let headerSize = try readUInt32(from: reader)
            guard headerSize > 0, headerSize <= 4_096 else { throw Failure.invalid }
            let entry = try JSONDecoder().decode(Entry.self, from: readExactly(Int(headerSize), from: reader))
            guard validPath(entry.path), names.insert(entry.path).inserted else { throw Failure.invalid }
            guard entry.size <= maxFile, entry.path != "library.json" || entry.size <= 64 * 1024 * 1024 else { throw Failure.limit }
            total += entry.size
            guard total <= maxTotal else { throw Failure.limit }
            let file = staging.appendingPathComponent(entry.path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: file.path, contents: nil)
            let writer = try FileHandle(forWritingTo: file)
            var remaining = entry.size
            var crc: UInt32 = 0xFFFFFFFF
            do {
                while remaining > 0 {
                    try Task.checkCancellation()
                    let data = try readExactly(Int(min(UInt64(chunkSize), remaining)), from: reader)
                    try writer.write(contentsOf: data)
                    crc = Self.updateCRC(crc, data: data)
                    remaining -= UInt64(data.count)
                }
                try writer.close()
            } catch { try? writer.close(); throw error }
            guard try readUInt32(from: reader) == (crc ^ 0xFFFFFFFF) else { throw Failure.damaged }
        }
        guard (try reader.read(upToCount: 1) ?? Data()).isEmpty else { throw Failure.invalid }
        var snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(contentsOf: staging.appendingPathComponent("library.json")))
        guard [1, 2].contains(snapshot.version), snapshot.tracks.count <= 100_000,
              snapshot.events.count <= 2_000_000,
              Set(snapshot.tracks.map(\.id)).count == snapshot.tracks.count,
              Set(snapshot.playlists.map(\.id)).count == snapshot.playlists.count,
              Set(snapshot.events.map(\.id)).count == snapshot.events.count else { throw Failure.invalid }
        let needed = try referencedPaths(snapshot)
        guard names == needed.union(["library.json"]) else { throw Failure.damaged }
        var renamed: [String: String] = [:]
        var installed: [URL] = []
        do {
            for path in needed.sorted() {
                let section = path.hasPrefix("Audio/") ? "Audio" : "Artwork"
                let suffix = (path as NSString).pathExtension
                let newName = UUID().uuidString + (suffix.isEmpty ? "" : "." + suffix)
                let destination = root.appendingPathComponent(section).appendingPathComponent(newName)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: staging.appendingPathComponent(path), to: destination)
                installed.append(destination); renamed[path] = newName
            }
            for index in snapshot.tracks.indices {
                if !snapshot.tracks[index].fileName.isEmpty {
                    snapshot.tracks[index].fileName = renamed["Audio/" + snapshot.tracks[index].fileName]!
                }
                if let art = snapshot.tracks[index].artworkName { snapshot.tracks[index].artworkName = renamed["Artwork/" + art] }
                snapshot.tracks[index].variants = snapshot.tracks[index].variants?.map { variant in
                    var copy = variant
                    if let local = variant.localFileName { copy.localFileName = renamed["Audio/" + local] }
                    return copy
                }
            }
            snapshot.version = 2
            return Restored(snapshot: snapshot, installedFiles: installed)
        } catch { installed.forEach { try? fm.removeItem(at: $0) }; throw error }
    }

    private func referencedPaths(_ snapshot: LibrarySnapshot) throws -> Set<String> {
        var result = Set<String>()
        for track in snapshot.tracks {
            guard track.duration.isFinite, track.duration >= 0 else { throw Failure.invalid }
            if !track.fileName.isEmpty { result.insert("Audio/" + track.fileName) }
            if let name = track.artworkName { result.insert("Artwork/" + name) }
            for variant in track.variants ?? [] {
                if let name = variant.localFileName { result.insert("Audio/" + name) }
            }
        }
        guard result.allSatisfy(validPath) else { throw Failure.invalid }
        return result
    }
    private func validPath(_ path: String) -> Bool {
        if path == "library.json" { return true }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, ["Audio", "Artwork"].contains(String(parts[0])) else { return false }
        let name = String(parts[1])
        return !name.isEmpty && name.utf8.count <= 220 && name != "." && name != ".." &&
            name.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0) }
    }
    private func writeHeader(_ header: Entry, to file: FileHandle) throws {
        let data = try JSONEncoder().encode(header)
        try writeUInt32(UInt32(data.count), to: file)
        try file.write(contentsOf: data)
    }
    private func writeUInt32(_ value: UInt32, to file: FileHandle) throws {
        var big = value.bigEndian
        try withUnsafeBytes(of: &big) { try file.write(contentsOf: Data($0)) }
    }
    private func readUInt32(from file: FileHandle) throws -> UInt32 {
        let data = try readExactly(4, from: file)
        return data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    private func readExactly(_ count: Int, from file: FileHandle) throws -> Data {
        var result = Data()
        while result.count < count {
            guard let chunk = try file.read(upToCount: count - result.count), !chunk.isEmpty else { throw Failure.damaged }
            result.append(chunk)
        }
        return result
    }
    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0xEDB88320 : value >> 1 }
        return value
    }
    private static func updateCRC(_ value: UInt32, data: Data) -> UInt32 {
        var crc = value
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc
    }
    private static func crc32(_ data: Data) -> UInt32 { updateCRC(0xFFFFFFFF, data: data) ^ 0xFFFFFFFF }
}
