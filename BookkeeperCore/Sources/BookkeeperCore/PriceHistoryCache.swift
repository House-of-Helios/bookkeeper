import Foundation

/// Disk cache for `HistoricalPriceService` results, one JSON file per `key_days`.
///
/// Short TTL, unlike `IconCache`'s "cache forever" — DefiLlama is free and unthrottled,
/// so there's no budget reason to hold onto a stale curve once it's old enough that
/// today's point would be missing from it.
public actor PriceHistoryCache {
    private let dir: URL
    private static let ttl: TimeInterval = 15 * 60

    /// `directory` is the data root the cache lives under (`pricehistory/` inside it).
    public init(directory: URL? = nil) {
        dir = (directory ?? DataRoot.url)
            .appendingPathComponent("pricehistory", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    public func points(for key: String, days: Int) -> [PricePoint]? {
        let url = fileURL(key, days)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < Self.ttl,
              let data = try? Data(contentsOf: url),
              let points = try? JSONDecoder().decode([PricePoint].self, from: data)
        else { return nil }
        return points
    }

    public func store(_ points: [PricePoint], for key: String, days: Int) {
        guard let data = try? JSONEncoder().encode(points) else { return }
        try? data.write(to: fileURL(key, days))
    }

    private func fileURL(_ key: String, _ days: Int) -> URL {
        let safe = key.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return dir.appendingPathComponent("\(safe)_\(days)d.json")
    }
}
