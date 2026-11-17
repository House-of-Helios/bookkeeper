import Foundation

/// The one folder every store, cache and log lives under.
///
/// Resolved once per process, in this order:
/// 0. `--rehearse-launch <path>` (see `LaunchRehearsal`) — first, so a rehearsal can
///    never fall through to the real folder,
/// 1. `--data-dir <path>` on the command line,
/// 2. the `BOOKKEEPER_DATA_DIR` environment variable,
/// 3. the `BookkeeperDataDir` key in the app's Info.plist — set only in the Dev app
///    (`scripts/make-dev-app.sh`), so a Finder launch lands in `_DevData/` even when
///    Launch Services drops the `LSEnvironment` copy of the same path,
/// 4. `~/Library/Application Support/Bookkeeper/` — or, inside a test process, a fresh
///    temporary folder instead (see `isUnderTest`).
///
/// One resolver because the failure it prevents has already happened: each type built
/// its own Application Support path, so isolating one store in a test left the others
/// pointed at the real files — and fixture totals landed in the user's own history.
/// A run against `_DevData/` (or a test) reroutes everything by naming one folder.
public enum DataRoot {
    public static let argument = "--data-dir"
    public static let environmentKey = "BOOKKEEPER_DATA_DIR"
    public static let infoKey = "BookkeeperDataDir"

    /// The live root for this process.
    public static let url: URL = resolve(arguments: CommandLine.arguments,
                                         environment: ProcessInfo.processInfo.environment,
                                         info: Bundle.main.infoDictionary ?? [:],
                                         fallback: isUnderTest ? testURL : defaultURL)

    /// True when XCTest is loaded into this process. The app never links it, so this is
    /// only ever true in a test run — where it swaps the default for a throwaway folder.
    /// Decided here rather than by a test-side setup because `url` is resolved once, on
    /// first touch, and no test hook is guaranteed to run before the first `BookkeeperLog`
    /// line: a guard that can be forgotten or outrun is how fixture data reached the
    /// owner's files before.
    static var isUnderTest: Bool { NSClassFromString("XCTestCase") != nil }

    /// One folder per test process, so parallel runs never share a root.
    private static var testURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("bookkeeper-test-root-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
    }

    /// Where the data lives with nothing overriding it. The only place in the app that
    /// builds the Application Support path.
    public static var defaultURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bookkeeper", isDirectory: true)
    }

    /// The argument wins over the environment, the environment over the Info.plist key,
    /// and any of them over the default. An empty value counts as not given, so
    /// `BOOKKEEPER_DATA_DIR=` can't point the app at the current directory by accident.
    public static func resolve(arguments: [String], environment: [String: String],
                               info: [String: Any] = [:],
                               fallback: @autoclosure () -> URL = defaultURL) -> URL {
        if let rehearsal = LaunchRehearsal.requestedDirectory(arguments: arguments) {
            return rehearsal
        }
        if let i = arguments.firstIndex(of: argument), i + 1 < arguments.count {
            let path = arguments[i + 1].trimmingCharacters(in: .whitespaces)
            if !path.isEmpty { return folder(path) }
        }
        if let path = environment[environmentKey]?.trimmingCharacters(in: .whitespaces),
           !path.isEmpty {
            return folder(path)
        }
        if let path = (info[infoKey] as? String)?.trimmingCharacters(in: .whitespaces),
           !path.isEmpty {
            return folder(path)
        }
        return fallback()
    }

    static func folder(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL
    }

    /// Everything that must happen on launch before any store opens a file: the one-time
    /// copy of the v1 files, then the spending folder. The app skips this in `--snapshot`
    /// mode, which renders from the mock and must leave the data folder alone.
    public static func prepareForLaunch(at root: URL = url) {
        V1Backup.runIfNeeded(root: root)
        SpendingFolder.ensure(root: root)
        SpendingFolder.upgrade(root: root)
    }
}

/// A one-time copy of every v1 file into `backups/pre-2.0.0/`, made on the first 2.0
/// launch before anything else touches the folder.
///
/// Only the files that can't be rebuilt travel: wallets (and keys), the archive, the
/// last quotes. Icon and price-history caches download again on their own.
public enum V1Backup {
    public static let folderName = "pre-2.0.0"
    public static let files = ["wallets.txt", "history.csv", "quotes.json"]

    public static func directory(in root: URL) -> URL {
        root.appendingPathComponent("backups", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// Copy the v1 files if no backup exists yet. Returns the names copied — empty when
    /// a backup already exists (it is never overwritten, not even partly) or when there
    /// is nothing to back up (a fresh install needs no backup folder).
    @discardableResult
    public static func runIfNeeded(root: URL) -> [String] {
        let fm = FileManager.default
        let dest = directory(in: root)
        guard !fm.fileExists(atPath: dest.path) else { return [] }
        let present = files.filter { fm.fileExists(atPath: root.appendingPathComponent($0).path) }
        guard !present.isEmpty else { return [] }

        // Built under a temporary name and moved into place whole, so a launch killed
        // halfway leaves no half-filled `pre-2.0.0` that the next launch would trust.
        let backups = dest.deletingLastPathComponent()
        let staging = backups.appendingPathComponent(".\(folderName)-\(UUID().uuidString)",
                                                     isDirectory: true)
        do {
            try fm.createDirectory(at: backups, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try fm.createDirectory(at: staging, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            for name in present {
                let to = staging.appendingPathComponent(name)
                try fm.copyItem(at: root.appendingPathComponent(name), to: to)
                // Owner-only, like the originals: wallets.txt holds keys.
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: to.path)
            }
            try fm.moveItem(at: staging, to: dest)
            return present
        } catch {
            // Not logged: `BookkeeperLog` writes to the live root, and a test running
            // this against a temp root must not reach it.
            try? fm.removeItem(at: staging)
            return []
        }
    }
}

/// `spending/` — the 2.0 ledger's own folder, beside the v1 files and never mixed in
/// with them. Owner-only, like the rest of the data.
public enum SpendingFolder {
    public static let schemaVersion = 1

    public static func directory(in root: URL) -> URL {
        root.appendingPathComponent("spending", isDirectory: true)
    }

    /// Create the folder and its `schema.json` if missing. An existing schema file is
    /// left exactly as it is — a later version may have written it.
    public static func ensure(root: URL) {
        let fm = FileManager.default
        let dir = directory(in: root)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        let schema = dir.appendingPathComponent("schema.json")
        guard !fm.fileExists(atPath: schema.path) else { return }
        let text = "{ \"version\": \(schemaVersion) }\n"
        try? text.write(to: schema, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: schema.path)
    }

    /// The version `schema.json` in this folder says, or nil with no readable file.
    public static func storedVersion(in dir: URL) -> Int? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("schema.json")),
              let map = try? JSONDecoder().decode([String: Int].self, from: data) else { return nil }
        return map["version"]
    }

    /// The steps that bring the folder up one version, keyed by the version they start
    /// from: `migrations[1]` turns a version-1 folder into version 2. Each step gets the
    /// `spending/` folder and rewrites only what it must. None yet — 1 is current.
    ///
    /// Taken from Actual Budget, which builds its data from a template and walks numbered
    /// migrations up to the running version: an update can change a file's shape safely
    /// because the change is a step that runs once, not a guess on every read.
    public static let migrations: [Int: (URL) throws -> Void] = [:]

    public enum Upgrade: Equatable {
        case current
        case migrated(from: Int, to: Int)
        /// Written by a newer Bookkeeper. Left untouched; the store opens it read-only.
        case newer(Int)
        /// A step failed. The folder stays at `at` and its backup holds the state before.
        case failed(at: Int, why: String)
    }

    /// Bring `spending/` up to `current`, once, at launch. The whole folder is copied to
    /// `spending/backups/pre-v<current>-<seconds>/` before the first step, and the version
    /// is stamped after each step, so a launch killed midway resumes at the right step.
    @discardableResult
    public static func upgrade(root: URL,
                               steps: [Int: (URL) throws -> Void] = migrations,
                               current: Int = schemaVersion) -> Upgrade {
        let dir = directory(in: root)
        guard var version = storedVersion(in: dir) else { return .current }
        if version > current { return .newer(version) }
        guard version < current else { return .current }
        let from = version
        do {
            try backUp(dir, as: "pre-v\(current)-\(Int(Date().timeIntervalSince1970))")
            while version < current {
                guard let step = steps[version] else {
                    throw NSError(domain: "Bookkeeper", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "no step from version \(version)"])
                }
                try step(dir)
                version += 1
                try stamp(version, in: dir)
            }
            return .migrated(from: from, to: current)
        } catch {
            return .failed(at: version, why: error.localizedDescription)
        }
    }

    private static func stamp(_ version: Int, in dir: URL) throws {
        let url = dir.appendingPathComponent("schema.json")
        try "{ \"version\": \(version) }\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Copied under a temporary name and moved into place whole, like `V1Backup`, so a
    /// half-made backup is never mistaken for a whole one.
    private static func backUp(_ dir: URL, as name: String) throws {
        let fm = FileManager.default
        let backups = dir.appendingPathComponent("backups", isDirectory: true)
        let staging = backups.appendingPathComponent(".\(name)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        do {
            for item in try fm.contentsOfDirectory(atPath: dir.path) where item != "backups" {
                try fm.copyItem(at: dir.appendingPathComponent(item), to: staging.appendingPathComponent(item))
            }
            try fm.moveItem(at: staging, to: backups.appendingPathComponent(name, isDirectory: true))
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }
}
