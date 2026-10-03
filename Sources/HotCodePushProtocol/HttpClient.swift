import Foundation

public struct HttpResponse {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        return headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// The three HTTP shapes the core needs: a small GET, a small POST and a large download that resumes.
public protocol HttpClient {
    func get(_ url: URL, headers: [String: String]) async throws -> HttpResponse
    func post(_ url: URL, headers: [String: String], body: Data) async throws -> HttpResponse
    /// Downloads to the file, appending from its current size with a `Range` request when it exists; what arrived stays when the
    /// connection drops, for the next attempt to resume. Past `maximumBytes`, or on a status other than 200 or 206, it stops and deletes the file.
    func download(_ url: URL, to file: URL, maximumBytes: Int, progress: @escaping (Int, Int) -> Void) async throws
}

public final class UrlSessionHttpClient: HttpClient {
    private static let chunkSize = 64 * 1024

    private let session: URLSession

    public init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    public func get(_ url: URL, headers: [String: String]) async throws -> HttpResponse {
        return try await send(UrlSessionHttpClient.request(url, method: "GET", headers: headers, body: nil))
    }

    public func post(_ url: URL, headers: [String: String], body: Data) async throws -> HttpResponse {
        return try await send(UrlSessionHttpClient.request(url, method: "POST", headers: headers, body: body))
    }

    private func send(_ request: URLRequest) async throws -> HttpResponse {
        let (data, response) = try await session.data(for: request)
        return HttpResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, headers: UrlSessionHttpClient.headers(of: response), body: data)
    }

    private static func request(_ url: URL, method: String, headers: [String: String], body: Data?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// Streams the body into the file chunk by chunk: a body larger than it may be never lands on disk whole, and a dropped connection leaves what arrived.
    public func download(_ url: URL, to file: URL, maximumBytes: Int, progress: @escaping (Int, Int) -> Void) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let existing = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        if existing > 0 {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
        }
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 206 else {
            try? FileManager.default.removeItem(at: file)
            throw DownloadFailure.downloadFailed("HTTP \(status) for \(url.lastPathComponent)")
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let isResumed = status == 206 && existing > 0
        if !isResumed {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var written = isResumed ? existing : 0
        var chunk: [UInt8] = []
        chunk.reserveCapacity(UrlSessionHttpClient.chunkSize)
        func writeChunk() throws {
            written += chunk.count
            guard written <= maximumBytes else {
                try? FileManager.default.removeItem(at: file)
                throw DownloadFailure.downloadFailed("\(url.lastPathComponent) is larger than its \(maximumBytes) bytes")
            }
            try handle.write(contentsOf: chunk)
            chunk.removeAll(keepingCapacity: true)
            progress(written, maximumBytes)
        }
        do {
            for try await byte in bytes {
                chunk.append(byte)
                if chunk.count == UrlSessionHttpClient.chunkSize {
                    try writeChunk()
                }
            }
            try writeChunk()
        } catch let dropped as URLError {
            try? writeChunk()
            throw dropped
        }
    }

    private static func headers(of response: URLResponse) -> [String: String] {
        guard let http = response as? HTTPURLResponse else { return [:] }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String {
                headers[name] = value
            }
        }
        return headers
    }
}
