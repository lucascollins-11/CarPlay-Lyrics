import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LyricsCore

/// An HTTPClient that answers from a closure and records every request.
final class StubHTTP: HTTPClient, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data, [String: String])

    private let lock = NSLock()
    private var handler: Handler
    private var _requests: [URLRequest] = []

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let handler = record(request)
        let (status, body, headers) = try handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (body, response)
    }

    private func record(_ request: URLRequest) -> Handler {
        lock.lock(); defer { lock.unlock() }
        _requests.append(request)
        return handler
    }
}

extension URLRequest {
    /// Query parameters as a dictionary.
    var query: [String: String] {
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    }

    var path: String { url?.path ?? "" }

    /// The form-encoded body as a dictionary.
    var form: [String: String] {
        guard let body = httpBody, let string = String(data: body, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for pair in string.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            result[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        return result
    }
}

func json(_ string: String) -> Data { Data(string.utf8) }

func makeTrack(id: String = "t1", title: String = "Song", artists: [String] = ["Artist"], album: String = "Album",
               duration: TimeInterval = 200) -> NowPlayingTrack {
    NowPlayingTrack(id: id, title: title, artists: artists, album: album, duration: duration)
}

/// Ten lines, one every 5 seconds starting at 2s: "line 0" ... "line 9".
func makeTimeline(count: Int = 10) -> LyricsTimeline {
    LyricsTimeline(lines: (0..<count).map { LyricLine(time: TimeInterval($0 * 5 + 2), text: "line \($0)") })
}

func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("LyricsCoreTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
