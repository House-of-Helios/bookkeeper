import Foundation

/// CoinGecko demo-API-key auth, shared by the price / search / icon services. Reads the
/// key lazily (a closure) so saving a key in Settings takes effect on the next call with
/// no service rebuild. When set, requests send `x-cg-demo-api-key`, lifting rate limits.
public struct CoinGeckoAuth: Sendable {
    private let key: @Sendable () -> String?

    public init(key: @escaping @Sendable () -> String? = { nil }) { self.key = key }

    public var headers: [String: String] {
        guard let k = key()?.trimmingCharacters(in: .whitespaces), !k.isEmpty else { return [:] }
        return ["x-cg-demo-api-key": k]
    }
}
