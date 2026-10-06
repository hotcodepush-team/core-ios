import XCTest
@testable import HotCodePushCore

final class HttpClientTests: XCTestCase {
    private let url = URL(string: "https://files.test/apps/a/bundles/b2/pack")!
    private var file: URL!

    override func setUp() {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("hotcodepush-tests-\(UUID().uuidString)").appendingPathComponent("b2.pack")
    }

    func testShouldResumeAPartialDownloadWithARangeRequestAndAppendTheRest() async throws {
        try writePartialFile("abc")
        var ranges: [String?] = []
        let client = StubUrlProtocol.client { request in
            ranges.append(request.value(forHTTPHeaderField: "Range"))
            return .init(status: 206, body: Data("defgh".utf8))
        }
        let error = await download(with: client, maximumBytes: 8)
        XCTAssertNil(error)
        XCTAssertEqual(ranges, ["bytes=3-"])
        XCTAssertEqual(try Data(contentsOf: file), Data("abcdefgh".utf8))
    }

    func testShouldStartOverWhenARangeRequestIsAnsweredWithTheWholeBody() async throws {
        try writePartialFile("abc")
        let client = StubUrlProtocol.client { _ in .init(status: 200, body: Data("abcdefgh".utf8)) }
        let error = await download(with: client, maximumBytes: 8)
        XCTAssertNil(error)
        XCTAssertEqual(try Data(contentsOf: file), Data("abcdefgh".utf8))
    }

    func testShouldDeleteThePartialFileOnAnotherStatus() async throws {
        try writePartialFile("abc")
        let client = StubUrlProtocol.client { _ in .init(status: 416, body: Data()) }
        let error = await download(with: client, maximumBytes: 8)
        XCTAssertEqual(error as? HttpStatusError, HttpStatusError(status: 416))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testShouldAnswerARedirectWithItsStatusAndNeverFollowIt() async throws {
        var requested: [URL?] = []
        let client = StubUrlProtocol.client { request in
            requested.append(request.url)
            return .init(status: 302, body: Data(), redirectLocation: URL(string: "https://elsewhere.test/pack"))
        }
        let error = await download(with: client, maximumBytes: 8)
        XCTAssertEqual(error as? HttpStatusError, HttpStatusError(status: 302))
        XCTAssertEqual(requested, [url])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testShouldKeepWhatArrivedWhenTheConnectionDropsAndResumeFromIt() async throws {
        let body = Data((0..<200_000).map { UInt8($0 % 251) })
        var ranges: [String?] = []
        let client = StubUrlProtocol.client { request in
            let range = request.value(forHTTPHeaderField: "Range")
            ranges.append(range)
            guard let start = range.flatMap({ Int($0.dropFirst("bytes=".count).dropLast()) }) else {
                return .init(status: 200, body: Data(body.prefix(150_000)), isInterrupted: true)
            }
            return .init(status: 206, body: Data(body.suffix(from: start)))
        }
        let interrupted = await download(with: client, maximumBytes: body.count)
        XCTAssertNotNil(interrupted)
        XCTAssertEqual(try Data(contentsOf: file), Data(body.prefix(150_000)))
        let resumed = await download(with: client, maximumBytes: body.count)
        XCTAssertNil(resumed)
        XCTAssertEqual(ranges, [nil, "bytes=150000-"])
        XCTAssertEqual(try Data(contentsOf: file), body)
    }

    func testShouldStopADownloadPastItsMaximumAndDeleteTheFile() async {
        let client = StubUrlProtocol.client { _ in .init(status: 200, body: Data(count: 200_000)) }
        let error = await download(with: client, maximumBytes: 100_000)
        XCTAssertEqual((error as? DownloadFailure)?.reason, .downloadFailed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    private func writePartialFile(_ content: String) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: file)
    }

    private func download(with client: UrlSessionHttpClient, maximumBytes: Int) async -> Error? {
        do {
            try await client.download(url, to: file, maximumBytes: maximumBytes) { _, _ in }
            return nil
        } catch {
            return error
        }
    }
}

/// Answers the real `URLSession` client's requests from a closure, so it runs without a network.
final class StubUrlProtocol: URLProtocol {
    struct Reply {
        let status: Int
        let body: Data
        /// The connection drops once the body has been read, as a network drops after what it delivered.
        var isInterrupted = false
        /// Where a redirect points; the loading system then asks the session whether to follow.
        var redirectLocation: URL?
    }

    static var reply: (URLRequest) -> Reply = { _ in Reply(status: 404, body: Data()) }

    static func client(_ reply: @escaping (URLRequest) -> Reply) -> UrlSessionHttpClient {
        StubUrlProtocol.reply = reply
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubUrlProtocol.self]
        return UrlSessionHttpClient(configuration: configuration)
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply = StubUrlProtocol.reply(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: [:])!
        if let location = reply.redirectLocation {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: location), redirectResponse: response)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        if reply.isInterrupted {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [client] in
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
