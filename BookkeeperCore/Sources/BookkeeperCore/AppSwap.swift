import Foundation

/// How an update goes in — XMRange's way. While the app still runs, the new build is copied
/// in beside it under a hidden name and checked; then the running bundle and the new one
/// trade places by rename (instant, on the same disk), the old one is deleted, and the new
/// one is opened. Nothing is left behind and nothing shows: no helper script, no
/// "(previous)" copy, no second app in Applications.
///
/// This type is the part that touches the disk by name, so it can be tested on fake
/// bundles; copying (`ditto`), checking (`codesign`) and opening live with the app.
public enum AppSwap {

    /// Where the new build is copied while the app runs: `.Bookkeeper.app.update`.
    public static func stagedURL(for installed: URL) -> URL {
        installed.deletingLastPathComponent().appendingPathComponent(".\(installed.lastPathComponent).update")
    }

    /// Where the running bundle steps aside for the moment of the swap: `.Bookkeeper.app.old`.
    public static func oldURL(for installed: URL) -> URL {
        installed.deletingLastPathComponent().appendingPathComponent(".\(installed.lastPathComponent).old")
    }

    /// Anything an update left beside the app — a swap cut short, or the copy the old
    /// shell helper kept as `Bookkeeper (previous).app`. Cleared at every launch.
    public static func leftovers(for installed: URL) -> [URL] {
        let name = installed.deletingPathExtension().lastPathComponent
        let previous = installed.deletingLastPathComponent()
            .appendingPathComponent("\(name) (previous)").appendingPathExtension("app")
        return [stagedURL(for: installed), oldURL(for: installed), previous]
    }

    public enum Failure: Error, Equatable {
        /// The running app couldn't step aside; nothing changed.
        case couldNotMoveAside
        /// The new build couldn't take the name; the running app was put back.
        case couldNotMoveIn
    }

    /// The new build (already copied to `staged` and checked) takes the installed name; the
    /// old one is deleted. On any failure the installed app is left where it was.
    public static func swap(installed: URL, staged: URL, fileManager fm: FileManager = .default) throws {
        let old = oldURL(for: installed)
        try? fm.removeItem(at: old)
        do { try fm.moveItem(at: installed, to: old) } catch {
            try? fm.removeItem(at: staged)
            throw Failure.couldNotMoveAside
        }
        do { try fm.moveItem(at: staged, to: installed) } catch {
            try? fm.moveItem(at: old, to: installed)
            try? fm.removeItem(at: staged)
            throw Failure.couldNotMoveIn
        }
        try? fm.removeItem(at: old)
    }

    /// Clears whatever `leftovers` finds. Returns what was removed.
    @discardableResult
    public static func clearLeftovers(for installed: URL, fileManager fm: FileManager = .default) -> [URL] {
        leftovers(for: installed).filter { fm.fileExists(atPath: $0.path) && (try? fm.removeItem(at: $0)) != nil }
    }
}
