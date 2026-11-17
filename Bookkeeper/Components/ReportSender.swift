import Foundation
import AppKit
import BookkeeperCore

/// Where a problem report goes when the person presses Send: the bundled `house-report`
/// (the House's one sender, built in XMRange) seals it for the House key and hands it to
/// Nostr relays, only through this app's own Tor port. Nothing here runs on its own.
struct ReportFailure: Error { let why: String }

@MainActor
enum ReportSender {
    /// Bookkeeper's own report key (hex x-only public key). Its private half lives only in
    /// the House's Bookkeeper folder; `scripts/check-reports.sh` collects with it. Other
    /// House apps have keys of their own, so their reports never mix.
    static let houseKey = "a67de37585e44d12f7fb4c7e4a6e44e34493697da926734687961d1c2036a970"

    private static var tool: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/house-report") }

    /// Can Send be offered at all in this build?
    static var ready: Bool {
        houseKey.count == 64 && FileManager.default.isExecutableFile(atPath: tool.path)
    }

    /// How many relays took the report, or why none did.
    static func send(text: String, kind: String, version: String) async -> Result<Int, ReportFailure> {
        guard ready else { return .failure(ReportFailure(why: "Sending isn't in this build. Copy or Save instead.")) }
        guard TorService.shared.state == .ready else {
            return .failure(ReportFailure(why: "Tor isn't connected, and reports only go through Tor. Copy or Save instead."))
        }
        let args = ["--to", houseKey, "--app", "bookkeeper", "--version", version, "--kind", kind,
                    "--socks", "127.0.0.1:\(TorService.port)"]
        let tool = self.tool
        return await Task.detached { () -> Result<Int, ReportFailure> in
            let p = Process()
            p.executableURL = tool
            p.arguments = args
            let input = Pipe(), output = Pipe(), errors = Pipe()
            p.standardInput = input; p.standardOutput = output; p.standardError = errors
            do { try p.run() } catch { return .failure(ReportFailure(why: "The sender would not start.")) }
            input.fileHandleForWriting.write(Data(text.utf8))
            try? input.fileHandleForWriting.close()
            let out = output.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus == 0,
               let j = try? JSONSerialization.jsonObject(with: out) as? [String: Any], let n = j["sent"] as? Int, n > 0 {
                return .success(n)
            }
            return .failure(ReportFailure(why: p.terminationStatus == 1
                ? "No relay took it through Tor just now. Copy or Save instead, or try again later."
                : "The report could not be sent. Copy or Save instead."))
        }.value
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
