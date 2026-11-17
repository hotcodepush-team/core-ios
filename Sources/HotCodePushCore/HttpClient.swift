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

/// A download answered with a status other than 200 or 206; a redirect is one, since a download follows none.
public struct HttpStatusError: Error, Equatable, LocalizedError {
    public let status: Int

    public init(status: Int) {
        self.status = status
    }

    public var errorDescription: String? { "HTTP \(status)" }
}

/// The four HTTP requests the core needs: a small GET, a small POST, a large download that resumes and a GET that reads nothing of its answer.
public protocol HttpClient {
    func get(_ url: URL, headers: [String: String]) async throws -> HttpResponse
    func post(_ url: URL, headers: [String: String], body: Data) async throws -> HttpResponse
    /// Downloads to the file, resuming from its current size with a `Range` request.
    /// What arrived stays when the connection drops. Past `maximumBytes` it deletes the file and refuses the pack as wrong content, `DownloadFailure.contentMismatched`.
    /// A write that fails on the device's storage throws `DownloadFailure.downloadFailed`.
    /// On a status other than 200 or 206, a redirect included, it deletes the file and throws `HttpStatusError`.
    func download(_ url: URL, to file: URL, maximumBytes: Int, progress: @escaping (Int, Int) -> Void) async throws
    /// Sends one GET and returns at its answer: it follows no redirect, reads no body and writes no file.
    /// Throws the transport error when the request gets no answer.
    func send(_ url: URL) async throws
}

/// The `HttpClient` on `URLSession`.
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
        return try await fetchResponse(UrlSessionHttpClient.request(url, method: "GET", headers: headers, body: nil))
    }

    public func post(_ url: URL, headers: [String: String], body: Data) async throws -> HttpResponse {
        return try await fetchResponse(UrlSessionHttpClient.request(url, method: "POST", headers: headers, body: body))
    }

    private func fetchResponse(_ request: URLRequest) async throws -> HttpResponse {
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

    public func send(_ url: URL) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let task = session.dataTask(with: request)
            transfers.beginSend(continuation, for: task)
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

    // The file is appended to when the server honours the range, else started over.
    func open(status: Int) throws {
        let isResumed = status == 206 && existing > 0
        stream = try writeToStorage {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let stream = OutputStream(url: file, append: isResumed) else { throw CocoaError(.fileWriteUnknown) }
            stream.open()
            return stream
        }
        written = isResumed ? existing : 0
    }

    func write(_ data: Data) throws {
        guard let stream = stream, !data.isEmpty else { return }
        try writeToStorage {
            try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < buffer.count {
                    let count = stream.write(buffer.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self), maxLength: buffer.count - offset)
                    guard count > 0 else { throw stream.streamError ?? CocoaError(.fileWriteUnknown) }
                    offset += count
                }
            }
        }
    }

    // The network and the device's own storage both fail with an error, so a failed write is told apart here.
    private func writeToStorage<Written>(_ write: () throws -> Written) throws -> Written {
        do {
            return try write()
        } catch {
            throw DownloadFailure.downloadFailed("The pack could not be written to the device's storage: \(error.localizedDescription)")
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

private final class TransferDelegate: NSObject, URLSessionDataDelegate {
    private let lock = NSLock()
    private var transfers: [Int: Transfer] = [:]
    private var sends: [Int: CheckedContinuation<Void, Error>] = [:]

    func begin(_ transfer: Transfer, for task: URLSessionTask) {
        lock.lock()
        transfers[task.taskIdentifier] = transfer
        lock.unlock()
    }

    func beginSend(_ continuation: CheckedContinuation<Void, Error>, for task: URLSessionTask) {
        lock.lock()
        sends[task.taskIdentifier] = continuation
        lock.unlock()
    }

    private func isSend(_ task: URLSessionTask) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sends[task.taskIdentifier] != nil
    }

    private func endSend(_ task: URLSessionTask) -> CheckedContinuation<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return sends.removeValue(forKey: task.taskIdentifier)
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
        if let send = endSend(dataTask) {
            completionHandler(.cancel)
            send.resume()
            return
        }
        guard let transfer = transfer(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 206 else {
            transfer.abandon(HttpStatusError(status: status))
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

    // A download and a send stay on the URL the core pinned, so a redirect is the answer.
    // URLSessionTaskDelegate's shape.
    // swiftlint:disable:next function_parameter_count
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(transfer(for: task) == nil && !isSend(task) ? request : nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let transfer = transfer(for: dataTask) else { return }
        transfer.written += data.count
        guard transfer.written <= transfer.maximumBytes else {
            transfer.abandon(DownloadFailure.contentMismatched("\(transfer.url.lastPathComponent) is larger than its \(transfer.maximumBytes) bytes"))
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
        if let send = endSend(task) {
            if let error = error {
                send.resume(throwing: error)
            } else {
                send.resume()
            }
            return
        }
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
