import Foundation
import AppKit
import BookkeeperCore

/// Where a problem report goes when the person presses Send. Not built yet: a Rust helper
/// will do the sending. The sheet already calls this one function, so only this body changes.
/// Swift wants an Error type in a Result, so the reason rides in this.
struct ReportFailure: Error { let why: String }

enum ReportSender {
    /// The new issue's number, or why it did not go.
    static func send(text: String) async -> Result<Int, ReportFailure> {
        .failure(ReportFailure(why: "not built yet"))
    }
}

/// A file named `running` in the data folder says the app is open. A clean quit takes it
/// away; if it is still there at the next launch, the last run ended some other way.
@MainActor
enum LastRun {
    private static var marker: URL { DataRoot.url.appendingPathComponent("running") }
    /// True when the previous run left its marker behind. Set once, at launch.
    static var endedBadly = false

    static func begin() {
        endedBadly = FileManager.default.fileExists(atPath: marker.path)
        try? Data().write(to: marker)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { _ in
            try? FileManager.default.removeItem(at: marker)
        }
    }
}
