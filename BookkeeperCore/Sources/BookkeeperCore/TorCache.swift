import Foundation

/// Arti keeps a fresh copy of the Tor network map (~3 MB) several times a day in its cache
/// folder. Left alone it reached 147 MB in three days of the Dev app. Bound it where it is
/// written: before Arti starts, a cache over the limit is removed whole. Arti fetches a new
/// map on start (a few MB, a slower first connect); its `state/` (guards) is never touched.
public enum TorCache {
    public static let limit: Int64 = 64 * 1024 * 1024

    /// Removes `cache` when its files add up to more than `limit` bytes. Returns true if removed.
    @discardableResult
    public static func trim(_ cache: URL, limit: Int64 = TorCache.limit) -> Bool {
        guard size(of: cache) > limit else { return false }
        return (try? FileManager.default.removeItem(at: cache)) != nil
    }

    static func size(of dir: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
