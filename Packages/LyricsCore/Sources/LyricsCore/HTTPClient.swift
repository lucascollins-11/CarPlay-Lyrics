import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The one network call everything goes through, so tests can stub it.
public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
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
}

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
