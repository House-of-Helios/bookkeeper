import Foundation

/// `--rehearse-launch <dir>`: the app runs its 2.0 launch path against `<dir>` and exits,
/// with no window and no network. `scripts/rehearse-update.sh` points it at a copy of a
/// frozen v1 data folder and checks every v1 file comes out byte for byte what went in —
/// the gate `scripts/release.sh` runs before a build is released.
///
/// The flag names the data root itself (`DataRoot.resolve` reads it before anything
/// else), so every store — including ones built with a default path — and the log land
/// in `<dir>`. A rehearsal has no way to reach the real folder.
public enum LaunchRehearsal {
    public static let argument = "--rehearse-launch"

    /// The folder named after the flag, if the flag is there with a non-empty value.
    public static func requestedDirectory(arguments: [String] = CommandLine.arguments) -> URL? {
        guard let i = arguments.firstIndex(of: argument), i + 1 < arguments.count else { return nil }
        let path = arguments[i + 1].trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : DataRoot.folder(path)
    }

    /// True only when the live root IS the rehearsal folder — checked before the app runs
    /// a rehearsal, so a resolver change can't quietly send one at the real data.
    public static func isSafe(_ dir: URL, liveRoot: URL = DataRoot.url) -> Bool {
        dir.standardizedFileURL == liveRoot.standardizedFileURL
            && dir.standardizedFileURL != DataRoot.defaultURL.standardizedFileURL
    }
}
