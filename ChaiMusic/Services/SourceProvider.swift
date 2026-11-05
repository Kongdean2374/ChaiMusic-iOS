import Foundation
import CryptoKit

struct WebDAVSource {
    let configuration: SourceConfiguration
    let credential: SourceCredential?
    let transport: SourceTransport

    func browse(_ folder: URL? = nil) async throws -> [RemoteEntry] {
        let root = Self.directory(configuration.baseURL)
        let requested = folder ?? root
        guard SourceTransport.sameOrigin(requested, root), Self.contained(requested, in: root) else { throw SourceFailure.invalidURL }
        let body = Data("<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/><d:getcontenttype/></d:prop></d:propfind>".utf8)
        let data = try await transport.data(url: Self.directory(requested), origin: root, credential: credential,
                                            method: "PROPFIND", body: body,
                                            headers: ["Depth": "1", "Content-Type": "application/xml; charset=utf-8"])
        if let xml = String(data: data, encoding: .utf8),
           xml.localizedCaseInsensitiveContains("<!DOCTYPE") || xml.localizedCaseInsensitiveContains("<!ENTITY") {
            throw SourceFailure.invalidResponse
        }
        let parser = DAVResponseParser(data: data)
        return try parser.entries(base: requested, root: root, source: configuration)
    }
    func allEntries() async throws -> [RemoteEntry] {
        var folders = [Self.directory(configuration.baseURL)]
        var seen = Set<String>()
        var tracks: [String: RemoteEntry] = [:]
        while let folder = folders.first {
            folders.removeFirst()
            try Task.checkCancellation()
            guard seen.insert(folder.absoluteString).inserted else { continue }
            guard seen.count <= 2_000 else { throw SourceFailure.tooManyItems }
            for entry in try await browse(folder) {
                if entry.isDirectory { folders.append(entry.url) }
                else { tracks[entry.id] = entry }
                guard tracks.count <= 20_000 else { throw SourceFailure.tooManyItems }
            }
        }
        return tracks.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    static func directory(_ url: URL) -> URL {
        url.absoluteString.hasSuffix("/") ? url : url.appendingPathComponent("")
    }
    static func contained(_ url: URL, in root: URL) -> Bool {
        let path = url.standardized.path
        let base = root.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path == "/" + base || path.hasPrefix("/" + base + "/") || base.isEmpty
    }
}

private final class DAVResponseParser: NSObject, XMLParserDelegate {
    private let parser: XMLParser
    private var responses: [(href: String, name: String, collection: Bool, success: Bool)] = []
    private var href = "", name = "", field = "", status = ""
    private var collection = false, insideResponse = false, successful = false
    init(data: Data) { parser = XMLParser(data: data); super.init(); parser.delegate = self; parser.shouldResolveExternalEntities = false }
    func entries(base: URL, root: URL, source: SourceConfiguration) throws -> [RemoteEntry] {
        guard parser.parse() else { throw SourceFailure.invalidResponse }
        var seen = Set<String>()
        return responses.compactMap { response in
            guard response.success, let url = URL(string: response.href, relativeTo: base)?.absoluteURL,
                  SourceTransport.sameOrigin(url, root), WebDAVSource.contained(url, in: root),
                  url.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) != base.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                  seen.insert(url.absoluteString).inserted else { return nil }
            let ext = url.pathExtension.lowercased()
            guard response.collection || ["m4a", "mp3", "aac", "wav", "aiff", "aif", "caf", "flac", "mp4"].contains(ext) else { return nil }
            let name = response.name.isEmpty ? url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent : response.name
            let stable = source.id.uuidString + ":" + url.absoluteString
            let variant = SourceVariant(id: StableSourceID.make(stable), sourceID: source.id, remoteID: url.absoluteString,
                                        url: url, sourceName: source.name)
            return RemoteEntry(id: url.absoluteString, title: response.collection ? name : (name as NSString).deletingPathExtension,
                               url: url, isDirectory: response.collection, variants: response.collection ? [] : [variant])
        }
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        field = local
        if local == "response" { insideResponse = true; href = ""; name = ""; collection = false; successful = false; status = "" }
        if local == "collection", insideResponse { collection = true }
        if local == "status" { status = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard insideResponse else { return }
        switch field { case "href": href += string; case "displayname": name += string; case "status": status += string; default: break }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if local == "status", status.contains(" 200 ") { successful = true }
        if local == "response" {
            responses.append((href.trimmingCharacters(in: .whitespacesAndNewlines), name, collection, successful))
            insideResponse = false
        }
        field = ""
    }
}

enum StableSourceID {
    static func make(_ value: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

struct HTTPPluginSource {
    let configuration: SourceConfiguration
    let credential: SourceCredential?
    let transport: SourceTransport
    let manifest: PluginManifest
    let base: URL

    static func load(configuration: SourceConfiguration, credential: SourceCredential?, transport: SourceTransport) async throws -> HTTPPluginSource {
        let manifestURL: URL
        if configuration.baseURL.pathExtension.lowercased() == "json" { manifestURL = configuration.baseURL }
        else { manifestURL = WebDAVSource.directory(configuration.baseURL).appendingPathComponent("manifest.json") }
        let data = try await transport.data(url: manifestURL, origin: configuration.baseURL, credential: credential)
        let manifest: PluginManifest
        do { manifest = try JSONDecoder().decode(PluginManifest.self, from: data); try manifest.validate() }
        catch { throw SourceFailure.invalidManifest }
        return HTTPPluginSource(configuration: configuration, credential: credential, transport: transport,
                                manifest: manifest, base: manifestURL.deletingLastPathComponent().appendingPathComponent(""))
    }
    func verify() async throws {
        let result: PluginHealth = try await get(manifest.health)
        guard result.ok else { throw SourceFailure.invalidResponse }
    }
    func catalog(query: String? = nil) async throws -> [RemoteEntry] {
        var cursor: String? = nil
        var visited = Set<String>()
        var entries: [String: RemoteEntry] = [:]
        for _ in 0..<200 {
            try Task.checkCancellation()
            var parameters: [String: String] = [:]
            if let query { parameters["q"] = query }
            if let cursor { parameters["cursor"] = cursor }
            let page: PluginPage = try await get(query == nil ? manifest.catalog : manifest.search, parameters: parameters)
            for item in page.items {
                guard !item.id.isEmpty, !item.title.isEmpty, (item.duration ?? 0).isFinite, (item.duration ?? 0) >= 0 else { throw SourceFailure.invalidResponse }
                entries[item.id] = entry(item)
                guard entries.count <= 20_000 else { throw SourceFailure.tooManyItems }
            }
            if page.complete {
                guard page.nextCursor == nil else { throw SourceFailure.invalidResponse }
                let result = Array(entries.values)
                guard let query, !query.isEmpty else { return result }
                return result.filter { "\($0.title) \($0.artist) \($0.album)".localizedCaseInsensitiveContains(query) }
            }
            guard let next = page.nextCursor, !next.isEmpty, visited.insert(next).inserted else { throw SourceFailure.incomplete }
            cursor = next
        }
        throw SourceFailure.incomplete
    }
    func resolve(_ variant: SourceVariant) async throws -> URL {
        guard let id = variant.remoteID else { throw SourceFailure.invalidResponse }
        let stream: PluginStream = try await get(manifest.stream, parameters: ["id": id])
        guard !stream.authorization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SourceFailure.permissionMissing }
        if let expected = variant.recordingID, stream.recordingID != expected { throw SourceFailure.identityMismatch }
        if let expiry = stream.expiresAt, expiry <= Date() { throw SourceFailure.invalidResponse }
        try SourceTransport.validateHTTPS(stream.url)
        return stream.url
    }
    func candidates(recordingID: String) async throws -> [SourceVariant] {
        guard let endpoint = manifest.candidates else { return [] }
        let response: PluginCandidatesResponse = try await get(endpoint, parameters: ["recordingID": recordingID])
        guard response.recordingID == recordingID else { throw SourceFailure.identityMismatch }
        guard response.variants.count <= 100 else { throw SourceFailure.tooManyItems }
        return try response.variants.map { item in
            guard item.recordingID == recordingID, !item.id.isEmpty,
                  (item.alignmentOffset ?? 0).isFinite else { throw SourceFailure.identityMismatch }
            return variant(item)
        }
    }
    func lyrics(recordingID: String) async throws -> [Lyrics] {
        guard let endpoint = manifest.lyrics else { return [] }
        let response: PluginLyricsResponse = try await get(endpoint, parameters: ["recordingID": recordingID])
        guard response.recordingID == recordingID else { throw SourceFailure.identityMismatch }
        guard !response.authorization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SourceFailure.permissionMissing }
        var lyrics = response.lrc.map { LRCParser.parse($0) } ?? Lyrics()
        lyrics.staticText = response.text
        lyrics.language = response.language ?? "未知"
        lyrics.source = configuration.name
        lyrics.recordingID = recordingID
        lyrics.confidence = "來源宣告同一錄音；請依實際聆聽確認對齊"
        if let translation = response.translationLRC {
            let translated = LRCParser.parse(translation)
            for index in lyrics.lines.indices {
                if let match = translated.lines.min(by: { abs($0.time - lyrics.lines[index].time) < abs($1.time - lyrics.lines[index].time) }),
                   abs(match.time - lyrics.lines[index].time) < 0.1 { lyrics.lines[index].translation = match.text }
            }
        }
        return lyrics.lines.isEmpty && (lyrics.staticText?.isEmpty ?? true) ? [] : [lyrics]
    }
    private func entry(_ track: PluginTrack) -> RemoteEntry {
        let baseVariant = SourceVariant(id: StableSourceID.make(configuration.id.uuidString + ":" + track.id),
                                        sourceID: configuration.id, remoteID: track.id, recordingID: track.recordingID, sourceName: configuration.name)
        let variants = (track.variants ?? []).filter { !$0.id.isEmpty && $0.recordingID == track.recordingID }.map(variant)
        return RemoteEntry(id: track.id, title: track.title, artist: track.artist ?? "未知演出者", album: track.album ?? "未知專輯",
                           url: configuration.baseURL, duration: track.duration ?? 0, recordingID: track.recordingID,
                           variants: [baseVariant] + variants.filter { $0.id != baseVariant.id })
    }
    private func variant(_ item: PluginVariant) -> SourceVariant {
        SourceVariant(id: StableSourceID.make(configuration.id.uuidString + ":" + item.id), sourceID: configuration.id,
                      remoteID: item.id, recordingID: item.recordingID, sourceName: configuration.name,
                      declaredQuality: item.quality, alignmentOffset: item.alignmentOffset ?? 0)
    }
    private func get<T: Decodable>(_ endpoint: String, parameters: [String: String] = [:]) async throws -> T {
        var expanded = endpoint
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        for (key, value) in parameters { expanded = expanded.replacingOccurrences(of: "{\(key)}", with: value.addingPercentEncoding(withAllowedCharacters: safe) ?? "") }
        guard let target = URL(string: expanded, relativeTo: base)?.absoluteURL,
              SourceTransport.sameOrigin(target, configuration.baseURL),
              var components = URLComponents(url: target, resolvingAgainstBaseURL: false) else { throw SourceFailure.invalidManifest }
        var query = components.queryItems ?? []
        for (key, value) in parameters where !endpoint.contains("{\(key)}") { query.append(URLQueryItem(name: key, value: value)) }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw SourceFailure.invalidManifest }
        let data = try await transport.data(url: url, origin: configuration.baseURL, credential: credential)
        do {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        } catch { throw SourceFailure.invalidResponse }
    }
}
