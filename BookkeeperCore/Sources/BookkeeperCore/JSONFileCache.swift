import Foundation

/// A tiny Codable-on-disk cache under the data root (`DataRoot`), so computed results
/// (P&L, the charts history curve) survive relaunch and load instantly.
public struct JSONFileCache<Value: Codable & Sendable>: Sendable {
    private let fileURL: URL

    public init(name: String, directory: URL? = nil) {
        let base = directory ?? DataRoot.url
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent(name)
    }

    public func load() -> Value? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    public func save(_ value: Value) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: fileURL)
    }
}
