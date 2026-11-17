import Foundation

/// Injection seam for HTTP data fetching — lets tests inject canned responses
/// without hitting the network.
public protocol DataFetcher: Sendable {
    func data(from url: URL, headers: [String: String]) async throws -> Data
    /// Like `data(from:headers:)` but bypasses the URL cache so prices are always
    /// fetched fresh from the origin. Default implementation forwards to `data`.
    func freshData(from url: URL, headers: [String: String]) async throws -> Data
    /// POST a JSON body. Default implementation hits the network; tests override.
    func postJSON(to url: URL, body: Data, headers: [String: String]) async throws -> Data
}

public extension DataFetcher {
    func freshData(from url: URL, headers: [String: String]) async throws -> Data {
        try await data(from: url, headers: headers)
    }

    func postJSON(to url: URL, body: Data, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = Net.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let (data, response) = try await Net.session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse, userInfo: [NSURLErrorFailingURLErrorKey: url])
        }
        return data
    }
}

/// Production implementation backed by `Net.session` — direct, or through Tor.
/// Throws `URLError(.badServerResponse)` for any non-2xx status code.
public struct URLSessionFetcher: DataFetcher {
    public init() {}

    public func data(from url: URL, headers: [String: String]) async throws -> Data {
        try await fetch(url, headers: headers, cachePolicy: .useProtocolCachePolicy)
    }

    /// Prices use this so a CDN/`Cache-Control` header can't serve a stale quote —
    /// every refresh hits the origin for the live number.
    public func freshData(from url: URL, headers: [String: String]) async throws -> Data {
        try await fetch(url, headers: headers, cachePolicy: .reloadIgnoringLocalCacheData)
    }

    private func fetch(_ url: URL, headers: [String: String],
                       cachePolicy: URLRequest.CachePolicy) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = cachePolicy
        request.timeoutInterval = Net.timeout   // fail fast on a slow/flaky endpoint (e.g. base.blockscout)
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await Net.session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse,
                           userInfo: [NSURLErrorFailingURLErrorKey: url])
        }
        return data
    }
}
