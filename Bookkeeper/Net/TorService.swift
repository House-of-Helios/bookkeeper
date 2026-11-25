import AppKit
import BookkeeperCore

/// Tor for every lookup Bookkeeper makes: Arti, the Tor Project's own client, bundled
/// beside the app's executable and run as a child process — the way XMRange runs it.
///
/// On by default. While it's on, `Net` routes every request to Arti's SOCKS port on
/// 127.0.0.1 from the first moment, so nothing goes out direct while Arti is still
/// connecting, and nothing falls back to direct if it stops: lookups fail, the last
/// prices stay on screen, and Settings says why. Arti's cache and state live in
/// `<data>/tor/`, so a second start takes seconds instead of a minute.
@Observable @MainActor
final class TorService {
    static let shared = TorService()

    enum State: Equatable {
        case off, starting, ready
        case failed(String)
    }

    private(set) var state: State = .off
    /// How many times Tor has come up this run — the first is the launch's, which the
    /// refresh loop is already waiting on.
    private(set) var readies = 0

    /// Bookkeeper's ports (PORTS.md, 38xx): the app 3840, Bookkeeper Dev 3841 — so the two
    /// never fight over one if both run on a Mac.
    static var port: Int { SpendingImporter.isDevApp ? 3841 : 3840 }
    /// A first start downloads the Tor directory: ~12 s measured, XMRange once saw 90 s.
    static let bootstrapLimit: Duration = .seconds(180)
    private static let key = "torEnabled"

    var enabled: Bool { UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true }

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var output = ""
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Bumped per start, so an earlier start's timeout never fails a later one.
    @ObservationIgnored private var attempt = 0

    private var dir: URL { DataRoot.url.appendingPathComponent("tor", isDirectory: true) }
    private var pidFile: URL { dir.appendingPathComponent("arti.pid") }

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TorService.shared.stopProcess() }
        }
    }

    /// Route `Net` and start or stop Arti to match the setting. Called once at launch,
    /// before any request, and again whenever the setting changes.
    func apply() {
        if enabled {
            Net.torPort = Self.port
            start()
        } else {
            stopProcess()
            Net.torPort = nil
            state = .off
            settle()
        }
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.key)
        apply()
    }

    /// Try again after a failure.
    func restart() {
        stopProcess()
        apply()
    }

    /// Returns once Tor is ready, has failed, or is off — what the first refresh waits on.
    func settled() async {
        if state != .starting { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    // MARK: - Arti

    private func start() {
        guard process == nil else { return }
        guard let bin = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("arti"),
              FileManager.default.isExecutableFile(atPath: bin.path) else {
            fail("Tor isn't in this build")
            return
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let config = dir.appendingPathComponent("arti.toml")
            try configText.write(to: config, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
            stopStale()
            TorCache.trim(dir.appendingPathComponent("cache"))   // bound the network-map pile before Arti opens it

            let p = Process()
            p.executableURL = bin
            p.arguments = ["proxy", "-c", config.path]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            output = ""
            pipe.fileHandleForReading.readabilityHandler = { h in
                let chunk = String(decoding: h.availableData, as: UTF8.self)
                guard !chunk.isEmpty else { return }
                Task { @MainActor in TorService.shared.heard(chunk) }
            }
            p.terminationHandler = { _ in
                Task { @MainActor in TorService.shared.exited() }
            }
            try p.run()
            process = p
            try? String(p.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)
            state = .starting
            attempt += 1
            let mine = attempt
            Task {
                try? await Task.sleep(for: Self.bootstrapLimit)
                if state == .starting, attempt == mine {
                    stopProcess()
                    fail("Tor didn't connect in three minutes")
                }
            }
        } catch {
            fail("Tor couldn't start: \(error.localizedDescription)")
        }
    }

    private var configText: String {
        func q(_ u: URL) -> String { "\"\(u.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"" }
        return """
        [proxy]
        socks_listen = "127.0.0.1:\(Self.port)"
        dns_listen = 0

        [storage]
        cache_dir = \(q(dir.appendingPathComponent("cache")))
        state_dir = \(q(dir.appendingPathComponent("state")))

        [logging]
        console = "info"

        """
    }

    private func heard(_ chunk: String) {
        output = String((output + chunk).suffix(4000))
        if state == .starting, output.contains("Sufficiently bootstrapped") {
            state = .ready
            readies += 1
            settle()
        }
    }

    private func exited() {
        process = nil
        try? FileManager.default.removeItem(at: pidFile)
        if enabled, state == .starting || state == .ready { fail("Tor stopped") }
    }

    private func fail(_ why: String) {
        state = .failed(why)
        settle()
    }

    private func settle() {
        let w = waiters
        waiters = []
        w.forEach { $0.resume() }
    }

    func stopProcess() {
        guard let p = process else { return }
        process = nil
        p.terminationHandler = nil
        (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        p.terminate()
        try? FileManager.default.removeItem(at: pidFile)
    }

    /// An Arti left running by a launch that didn't get to stop it (a crash, a force quit)
    /// still holds the port. Stopped only if that process really is an Arti.
    private func stopStale() {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1
        else { return }
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", String(pid), "-o", "comm="]
        let out = Pipe()
        ps.standardOutput = out
        try? ps.run()
        ps.waitUntilExit()
        let name = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasSuffix("/arti") || name == "arti" { kill(pid, SIGTERM) }
    }
}
