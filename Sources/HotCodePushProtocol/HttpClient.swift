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

/// `URLSession` on the package's floor: completion handlers for the small requests, the session's delegate for the streamed download.
public final class UrlSessionHttpClient: HttpClient {
    private let session: URLSession
    private let transfers = TransferDelegate()

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        session = URLSession(configuration: configuration, delegate: transfers, delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    public func get(_ url: URL, headers: [String: String]) async throws -> HttpResponse {
        return try await send(UrlSessionHttpClient.request(url, method: "GET", headers: headers, body: nil))
    }

    public func post(_ url: URL, headers: [String: String], body: Data) async throws -> HttpResponse {
        return try await send(UrlSessionHttpClient.request(url, method: "POST", headers: headers, body: body))
    }

    private func send(_ request: URLRequest) async throws -> HttpResponse {
        return try await withCheckedThrowingContinuation { continuation in
            session.dataTask(with: request) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data = data, let response = response else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                continuation.resume(returning: HttpResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, headers: UrlSessionHttpClient.headers(of: response), body: data))
            }.resume()
        }
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

    /// Streams the body into the file as it arrives: a body larger than it may be never lands on disk whole, and a dropped connection leaves what arrived.
    public func download(_ url: URL, to file: URL, maximumBytes: Int, progress: @escaping (Int, Int) -> Void) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let existing = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        if existing > 0 {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let task = session.dataTask(with: request)
            transfers.begin(Transfer(url: url, file: file, maximumBytes: maximumBytes, existing: existing, progress: progress, continuation: continuation), for: task)
            task.resume()
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

/// One streamed download: where the bytes go, how many may come, and the continuation waiting for the end.
private final class Transfer {
    let url: URL
    let file: URL
    let maximumBytes: Int
    let existing: Int
    let progress: (Int, Int) -> Void
    let continuation: CheckedContinuation<Void, Error>
    var stream: OutputStream?
    var written = 0
    var failure: Error?

    init(url: URL, file: URL, maximumBytes: Int, existing: Int, progress: @escaping (Int, Int) -> Void, continuation: CheckedContinuation<Void, Error>) {
        self.url = url
        self.file = file
        self.maximumBytes = maximumBytes
        self.existing = existing
        self.progress = progress
        self.continuation = continuation
    }

    /// Opens the file for the body: appended to when the server honours the range, started over otherwise.
    func open(status: Int) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let isResumed = status == 206 && existing > 0
        guard let stream = OutputStream(url: file, append: isResumed) else { throw DownloadFailure.downloadFailed("\(file.lastPathComponent) could not be opened") }
        stream.open()
        self.stream = stream
        written = isResumed ? existing : 0
    }

    func write(_ data: Data) throws {
        guard let stream = stream, !data.isEmpty else { return }
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let count = stream.write(buffer.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self), maxLength: buffer.count - offset)
                guard count > 0 else { throw stream.streamError ?? DownloadFailure.downloadFailed("\(file.lastPathComponent) could not be written") }
                offset += count
            }
        }
    }

    func close() {
        stream?.close()
        stream = nil
    }

    func abandon(_ error: Error) {
        close()
        try? FileManager.default.removeItem(at: file)
        failure = error
    }
}

/// The session's delegate for the streamed downloads, one transfer per task.
private final class TransferDelegate: NSObject, URLSessionDataDelegate {
    private let lock = NSLock()
    private var transfers: [Int: Transfer] = [:]

    func begin(_ transfer: Transfer, for task: URLSessionTask) {
        lock.lock()
        transfers[task.taskIdentifier] = transfer
        lock.unlock()
    }

    private func transfer(for task: URLSessionTask) -> Transfer? {
        lock.lock()
        defer { lock.unlock() }
        return transfers[task.taskIdentifier]
    }

    private func end(_ task: URLSessionTask) -> Transfer? {
        lock.lock()
        defer { lock.unlock() }
        return transfers.removeValue(forKey: task.taskIdentifier)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let transfer = transfer(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 206 else {
            transfer.abandon(DownloadFailure.downloadFailed("HTTP \(status) for \(transfer.url.lastPathComponent)"))
            completionHandler(.cancel)
            return
        }
        do {
            try transfer.open(status: status)
            completionHandler(.allow)
        } catch {
            transfer.abandon(error)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let transfer = transfer(for: dataTask) else { return }
        transfer.written += data.count
        guard transfer.written <= transfer.maximumBytes else {
            transfer.abandon(DownloadFailure.downloadFailed("\(transfer.url.lastPathComponent) is larger than its \(transfer.maximumBytes) bytes"))
            dataTask.cancel()
            return
        }
        do {
            try transfer.write(data)
            transfer.progress(transfer.written, transfer.maximumBytes)
        } catch {
            transfer.abandon(error)
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let transfer = end(task) else { return }
        transfer.close()
        if let failure = transfer.failure {
            transfer.continuation.resume(throwing: failure)
        } else if let error = error {
            transfer.continuation.resume(throwing: error)
        } else {
            transfer.continuation.resume()
        }
    }
}
