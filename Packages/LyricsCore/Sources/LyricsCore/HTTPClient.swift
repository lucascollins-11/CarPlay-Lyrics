import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The one network call everything goes through, so tests can stub it.
public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Like `send`, plus when the server was working on the request, if the client can tell.
    func sendTimed(_ request: URLRequest) async throws -> (Data, HTTPURLResponse, HTTPExchangeWindow?)
}

extension HTTPClient {
    /// Clients that can't measure the exchange report no window.
    public func sendTimed(_ request: URLRequest) async throws -> (Data, HTTPURLResponse, HTTPExchangeWindow?) {
        let (data, response) = try await send(request)
        return (data, response, nil)
    }
}

/// The part of an HTTP exchange in which the server handled the request: after the request
/// was fully sent and before the first byte of the response came back. Connection setup
/// (DNS, TCP, TLS), which can take seconds on a weak signal, is not part of it, so a
/// position Spotify measured while handling the request is known to within this window.
public struct HTTPExchangeWindow: Equatable, Sendable {
    public var requestEnd: Date
    public var responseStart: Date

    public init(requestEnd: Date, responseStart: Date) {
        self.requestEnd = requestEnd
        self.responseStart = responseStart
    }
}

public enum HTTPClientError: Error, Equatable {
    case notHTTP
}

extension URLSession: HTTPClient {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HTTPClientError.notHTTP }
        return (data, http)
    }

    #if !canImport(FoundationNetworking)
    public func sendTimed(_ request: URLRequest) async throws -> (Data, HTTPURLResponse, HTTPExchangeWindow?) {
        let collector = MetricsCollector()
        let (data, response) = try await self.data(for: request, delegate: collector)
        guard let http = response as? HTTPURLResponse else { throw HTTPClientError.notHTTP }
        return (data, http, collector.window)
    }
    #endif
}

#if !canImport(FoundationNetworking)
/// Reads URLSessionTaskMetrics for a single request.
private final class MetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var metrics: URLSessionTaskMetrics?

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock(); defer { lock.unlock() }
        self.metrics = metrics
    }

    var window: HTTPExchangeWindow? {
        lock.lock(); defer { lock.unlock() }
        // The last network transaction is the one that produced the response (earlier ones are redirects).
        guard let transaction = metrics?.transactionMetrics.last(where: { $0.resourceFetchType == .networkLoad }),
              let sent = transaction.requestEndDate,
              let received = transaction.responseStartDate,
              received >= sent
        else { return nil }
        return HTTPExchangeWindow(requestEnd: sent, responseStart: received)
    }
}
#endif

/// Encodes `application/x-www-form-urlencoded` bodies (RFC 3986 unreserved characters pass through).
public enum FormEncoding {
    public static func encode(_ fields: [(String, String)]) -> String {
        fields.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }

    public static func escape(_ value: String) -> String {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
