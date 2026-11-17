import XCTest
@testable import BookkeeperCore

final class ProblemReportTests: XCTestCase {
    private let home = "/Users/someone"

    private func facts(_ lines: [String], note: String = "") -> ProblemReport.Facts {
        .init(version: "2.0.22", macOS: "15.2", arch: "arm64", theme: "light", torOn: true,
              wallets: 3, banks: 2, logLines: lines, note: note)
    }

    /// One needle per kind of private thing; none may survive into the report.
    func testNothingPrivateSurvives() {
        let needles = [
            "/Users/someone/Library/Application Support/Bookkeeper/wallets.txt",
            "/Users/otherperson/Desktop/x.csv",
            "0x52908400098527886E0F7030069857D2E4169EE7",
            "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq",
            "7EcDhSYGxXyscszYEp35KHN8vvw3svAuLKTzXwCFLtV",
            "192.168.1.23", "fe80::1c2b:3a4f:fe5d:6e7f", "2001:4860:4860:0:0:0:0:8888",
            "$4,506.20", "−$23.18", "1,234.56", "3200.00", "0.8123",
            "helios-mini.local", "my-router.lan", "someone@example.com",
        ]
        let report = ProblemReport.build(facts(needles.map { "2026-11-17  error near \($0)" },
                                               note: "it broke at 192.168.1.23 with $12.50"), home: home)
        for n in needles {
            XCTAssertFalse(report.contains(n), "leaked: \(n)")
        }
        XCTAssertFalse(report.contains("someone"))
        XCTAssertFalse(report.contains("otherperson"))
        XCTAssertFalse(report.contains("12.50"))
        XCTAssertTrue(ProblemReport.scrub("balance 12.50.", home: home) == "balance [amount].",
                      "an amount at the end of a sentence still goes")
    }

    /// What the House needs to fix things stays readable.
    func testUsefulPartsStay() {
        let report = ProblemReport.build(facts(["2026-11-17T12:01:03Z  request to coins.llama.fi failed: timed out (wallets.txt) on 2.0.22"],
                                               note: "Prices stopped"), home: home)
        XCTAssertTrue(report.contains("bookkeeper 2.0.22"))
        XCTAssertTrue(report.contains("macOS 15.2, arm64"))
        XCTAssertTrue(report.contains("coins.llama.fi"))
        XCTAssertTrue(report.contains("wallets.txt"))
        XCTAssertTrue(report.contains("12:01:03"), "a clock time is not an IPv6 address")
        XCTAssertTrue(report.contains("on 2.0.22"), "a version is not an amount")
        XCTAssertTrue(report.contains("Prices stopped"))
    }

    func testOnlyTheNewestLinesGo() {
        let lines = (1...100).map { "line \($0)" }
        let report = ProblemReport.build(facts(lines), home: home)
        XCTAssertTrue(report.contains("line 100"))
        XCTAssertFalse(report.contains("line 60\n"))
        XCTAssertTrue(report.contains("Last \(ProblemReport.logLimit) log lines"))
    }

    // MARK: - The docs' worked example

    /// What the app saw: a report with a private thing of every kind planted in it.
    static let exampleFacts = ProblemReport.Facts(
        version: "2.0.23", macOS: "15.2", arch: "arm64", theme: "light", torOn: true,
        wallets: 3, banks: 2,
        logLines: [
            "2026-11-17T12:01:03Z  launch 2.0.23",
            "2026-11-17T12:01:19Z  tor ready",
            "2026-11-17T12:02:44Z  price lookup for 0x52908400098527886E0F7030069857D2E4169EE7 failed",
            "2026-11-17T12:02:45Z  save failed: /Users/jane/Library/Application Support/Bookkeeper/wallets.txt",
            "2026-11-17T12:02:46Z  peer 192.168.1.23 on janes-macbook.local refused",
        ],
        note: "Balance showed $4,506.20 then 0. My e-mail is jane@example.com, wallet bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq.")

    static let exampleHome = "/Users/jane"

    static func exampleInput() -> String {
        let f = exampleFacts
        return """
        version \(f.version) · macOS \(f.macOS) · \(f.arch) · \(f.theme) · Tor \(f.torOn ? "on" : "off") · wallets \(f.wallets) · banks \(f.banks)

        note:
        \(f.note)

        log:
        \(f.logLines.joined(separator: "\n"))

        """
    }

    /// docs/site/examples/ holds the input and the exact text Send hands the sender, made by
    /// this code. Stale copies fail here; BOOKKEEPER_WRITE_EXAMPLES=1 rewrites them.
    func testDocsExampleIsCurrent() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/site/examples")
        let sent = ProblemReport.build(Self.exampleFacts, home: Self.exampleHome)
        let input = Self.exampleInput()
        for planted in ["0x52908400098527886E0F7030069857D2E4169EE7", "jane", "192.168.1.23",
                        "janes-macbook.local", "4,506.20", "example.com", "bc1qar0srrr7"] {
            XCTAssertTrue(input.contains(planted), "the example must plant \(planted)")
            XCTAssertFalse(sent.contains(planted), "the example leaks \(planted)")
        }
        if ProcessInfo.processInfo.environment["BOOKKEEPER_WRITE_EXAMPLES"] == "1" {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try input.write(to: dir.appendingPathComponent("report-input.txt"), atomically: true, encoding: .utf8)
            try sent.write(to: dir.appendingPathComponent("report-sent.txt"), atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("report-input.txt"), encoding: .utf8), input,
                       "docs/site/examples is stale: run with BOOKKEEPER_WRITE_EXAMPLES=1")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("report-sent.txt"), encoding: .utf8), sent,
                       "docs/site/examples is stale: run with BOOKKEEPER_WRITE_EXAMPLES=1")
    }
}
