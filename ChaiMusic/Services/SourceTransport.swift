import Foundation

private final class SourceSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    // 認證與音訊網址均不自動重新導向，避免跨主機傳送帳密或降級連線。
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

actor SourceTransport {
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: SourceSessionDelegate(), delegateQueue: nil)
    }
    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased() &&
        a.host?.lowercased() == b.host?.lowercased() && (a.port ?? 443) == (b.port ?? 443)
    }
    static func validateHTTPS(_ url: URL, root: Bool = false) throws {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil,
              !root || url.query == nil else { throw SourceFailure.invalidURL }
    }
    func data(url: URL, origin: URL, credential: SourceCredential?, method: String = "GET", body: Data? = nil, headers: [String: String] = [:]) async throws -> Data {
        let request = try request(url: url, origin: origin, credential: credential, method: method, body: body, headers: headers)
        do {
            let (bytes, response) = try await session.bytes(for: request)
            try validate(response: response, maximum: 8 * 1024 * 1024)
            var output = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard output.count < 8 * 1024 * 1024 else { throw SourceFailure.tooLarge }
                output.append(byte)
            }
            return output
        } catch is CancellationError { throw CancellationError() }
        catch let error as SourceFailure { throw error }
        catch { throw SourceFailure.network }
    }
    func download(url: URL, origin: URL, credential: SourceCredential?, destination: URL) async throws {
        let request = try request(url: url, origin: origin, credential: credential)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".partial")
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let (bytes, response) = try await session.bytes(for: request)
            try validate(response: response, maximum: 512 * 1024 * 1024)
            FileManager.default.createFile(atPath: temporary.path, contents: nil)
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            var buffer = Data(); buffer.reserveCapacity(65_536)
            var count = 0
            for try await byte in bytes {
                try Task.checkCancellation()
                count += 1
                guard count <= 512 * 1024 * 1024 else { throw SourceFailure.tooLarge }
                buffer.append(byte)
                if buffer.count >= 65_536 { try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
            }
            if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
            try handle.synchronize()
            guard count > 0 else { throw SourceFailure.invalidResponse }
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            if error is CancellationError { throw CancellationError() }
            if let specific = error as? SourceFailure { throw specific }
            throw SourceFailure.network
        }
    }
    private func request(url: URL, origin: URL, credential: SourceCredential?, method: String = "GET", body: Data? = nil, headers: [String: String] = [:]) throws -> URLRequest {
        try Self.validateHTTPS(url)
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let credential, Self.sameOrigin(url, origin), !credential.username.isEmpty || !credential.password.isEmpty {
            let token = Data("\(credential.username):\(credential.password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
    private func validate(response: URLResponse, maximum: Int) throws {
        guard let response = response as? HTTPURLResponse else { throw SourceFailure.invalidResponse }
        switch response.statusCode {
        case 200...299: break
        case 300...399: throw SourceFailure.redirect
        case 401: throw SourceFailure.unauthorized
        case 403: throw SourceFailure.forbidden
        default: throw SourceFailure.invalidResponse
        }
        guard response.expectedContentLength <= Int64(maximum) else { throw SourceFailure.tooLarge }
    }
}
