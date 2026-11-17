import Foundation
import AppKit
import BookkeeperCore

/// Installs a downloaded update, XMRange's way (`AppSwap`), in two halves:
///
/// - `stage` — while this app still runs, copy the new version beside it under a hidden
///   name and check its signature. `Updater` runs this in the background as soon as an
///   update is downloaded, so Install rarely waits.
/// - `finish` — stop Tor, trade places by rename, open the new build and quit.
///
/// If anything before the swap fails, the app carries on as it was and says why.
enum AppInstaller {
    static var installed: URL { Bundle.main.bundleURL }

    /// Builds the new version at `AppSwap.stagedURL` from the unpacked `sourceApp` and
    /// checks it. Returns why it stopped, or nil when ready.
    static func stage(from sourceApp: URL) async -> String? {
        let installed = installed
        var isDir: ObjCBool = false
        guard sourceApp.pathExtension == "app",
              FileManager.default.fileExists(atPath: sourceApp.path, isDirectory: &isDir), isDir.boolValue
        else { return "The update didn't unpack to a Bookkeeper.app." }
        let staged = AppSwap.stagedURL(for: installed)
        let bundleId = Bundle.main.bundleIdentifier ?? "com.houseofhelios.bookkeeper"

        return await Task.detached {
            try? FileManager.default.removeItem(at: staged)
            guard run("/usr/bin/ditto", [sourceApp.path, staged.path]).ok else {
                try? FileManager.default.removeItem(at: staged)
                return "Couldn't copy the update."
            }
            // Ad-hoc signed, so no team to pin: the bundle id is checked instead, which
            // still catches a damaged or mismatched build. `=` marks requirement text.
            let check = run("/usr/bin/codesign", ["--verify", "--strict", "--deep", "-R", "=identifier \"\(bundleId)\"", staged.path])
            guard check.ok else {
                try? FileManager.default.removeItem(at: staged)
                return "The update didn't check out (its signature), so it wasn't installed."
            }
            return nil
        }.value
    }

    /// Swaps the staged build in and restarts into it. Returns why it stopped; on success
    /// it doesn't return, since this app quits.
    @MainActor
    static func finish() -> String? {
        let installed = installed
        let staged = AppSwap.stagedURL(for: installed)
        TorService.shared.stopProcess()
        do { try AppSwap.swap(installed: installed, staged: staged) } catch {
            TorService.shared.apply()
            return "Couldn't swap in the update — Bookkeeper is unchanged."
        }
        // If it won't open, stay up and say so: the new build is already in place, so
        // opening Bookkeeper by hand finishes the update.
        guard run("/usr/bin/open", ["-n", installed.path]).ok else {
            return "Update installed — open Bookkeeper again to finish."
        }
        NSApp.terminate(nil)
        return nil
    }

    /// Runs a tool; `why` holds its last error line (or the exit code) when it fails. A
    /// tool still running after `limit` seconds is stopped and counts as failed.
    nonisolated private static func run(_ tool: String, _ args: [String],
                                        limit: TimeInterval = 120) -> (ok: Bool, why: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let err = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = err
        do { try p.run() } catch { return (false, "couldn't start \(tool): \(error.localizedDescription)") }
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + limit, execute: timer)
        let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        timer.cancel()
        if p.terminationStatus == 0 { return (true, "") }
        if p.terminationReason == .uncaughtSignal { return (false, "stopped after \(Int(limit))s") }
        let last = text.split(separator: "\n").last.map(String.init) ?? ""
        return (false, last.isEmpty ? "exit \(p.terminationStatus)" : last)
    }
}
