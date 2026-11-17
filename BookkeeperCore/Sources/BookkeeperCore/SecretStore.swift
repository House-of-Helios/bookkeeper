import Foundation

/// A wallet entry read from the plaintext secret file.
///
/// A wallet is a name and nothing else. It used to carry an address and the chains to
/// scan it on; every holding is now entered by hand, so there is nothing to scan and an
/// address would be a secret stored for no reason.
public struct WalletSecret: Sendable, Equatable {
    public let nickname: String
    /// Optional network label for a manual (non-EVM) wallet (e.g. "Sia").
    public let network: String

    public init(nickname: String, network: String = "") {
        self.nickname = nickname
        self.network = network
    }
}

/// Reads and writes the plaintext wallet / API-key file at `wallets.txt` under the data
/// root (`DataRoot`).
///
/// File format (one entry per line):
/// - Wallet line:  `nickname\t\t\tnetwork`
/// - API-key line: `#key\tNAME\tVALUE`
///
/// Fields 2 and 3 are the retired address and scan-chain columns. They are still written
/// as empty and still skipped on read, because a file written before scanning was removed
/// has real values there and must keep loading — the position of `network` depends on it.
///
/// Pass a `directory:` URL in tests to redirect to a temporary folder.
public final class SecretStore: Sendable {
    private let fileURL: URL

    public init(directory: URL? = nil) {
        let base = directory ?? DataRoot.url
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]   // owner-only dir (holds addresses + keys)
        )
        fileURL = base.appendingPathComponent("wallets.txt")
    }

    // MARK: - Wallets

    public func loadWallets() -> [WalletSecret] {
        readLines().compactMap(parseWallet)
    }

    public func addWallet(_ w: WalletSecret) {
        var lines = readLines()
        lines.append("\(w.nickname)\t\t\t\(w.network)")
        writeLines(lines)
    }

    public func removeWallet(nickname: String) {
        let updated = readLines().filter { line in
            guard !line.hasPrefix("#") else { return true }
            let parts = line.components(separatedBy: "\t")
            return parts.first != nickname
        }
        writeLines(updated)
    }

    /// Set the manual-network label on an existing wallet line (4th tab field).
    public func setWalletNetwork(nickname: String, network: String) {
        let updated = readLines().map { line -> String in
            guard !line.hasPrefix("#") else { return line }
            var parts = line.components(separatedBy: "\t")
            guard parts.first == nickname, parts.count >= 3 else { return line }
            while parts.count < 4 { parts.append("") }
            parts[3] = network
            return parts.joined(separator: "\t")
        }
        writeLines(updated)
    }

    // MARK: - API keys

    public func apiKey(_ name: String) -> String? {
        readLines().compactMap { line -> String? in
            guard line.hasPrefix("#key\t") else { return nil }
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3, parts[1] == name else { return nil }
            return parts[2]
        }.first
    }

    public func setAPIKey(_ name: String, _ value: String?) {
        // Strip any existing entry for this key name
        var lines = readLines().filter { line in
            guard line.hasPrefix("#key\t") else { return true }
            let parts = line.components(separatedBy: "\t")
            return !(parts.count >= 2 && parts[1] == name)
        }
        if let value {
            lines.append("#key\t\(name)\t\(value)")
        }
        writeLines(lines)
    }

    // MARK: - Manually hidden tokens

    /// Token ids the user has chosen to hide (stored as `#hide\t<id>` lines).
    public func hiddenTokenIDs() -> [String] {
        readLines().compactMap { line in
            guard line.hasPrefix("#hide\t") else { return nil }
            let parts = line.components(separatedBy: "\t")
            return parts.count >= 2 ? parts[1] : nil
        }
    }

    public func hideToken(_ id: String) {
        var lines = readLines()
        guard !lines.contains("#hide\t\(id)") else { return }
        lines.append("#hide\t\(id)")
        writeLines(lines)
    }

    public func unhideToken(_ id: String) {
        let updated = readLines().filter { $0 != "#hide\t\(id)" }
        writeLines(updated)
    }

    // MARK: - Wallet presentation (name, colour, order)

    /// Rename a wallet. The nickname is the wallet's identity everywhere — manual
    /// holdings are keyed by it — so both the wallet line and every holding attached to
    /// it move together, or the rename would orphan the hand-entered tokens.
    public func renameWallet(from old: String, to new: String) {
        let clean = new.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, clean != old, !clean.contains("\t") else { return }
        let updated = readLines().map { line -> String in
            var parts = line.components(separatedBy: "\t")
            if line.hasPrefix("#manual\t"), parts.count >= 2, parts[1] == old {
                parts[1] = clean
                return parts.joined(separator: "\t")
            }
            if line.hasPrefix("#wmeta\t"), parts.count >= 2, parts[1] == old {
                parts[1] = clean
                return parts.joined(separator: "\t")
            }
            if line.hasPrefix("#wpos\t"), parts.count >= 2, parts[1] == old {
                parts[1] = clean
                return parts.joined(separator: "\t")
            }
            if !line.hasPrefix("#"), parts.first == old {
                parts[0] = clean
                return parts.joined(separator: "\t")
            }
            return line
        }
        writeLines(updated)
        // Carry the wallet's place in the order across the rename.
        let order = walletOrder().map { $0 == old ? clean : $0 }
        setWalletOrder(order)
    }

    /// Stored as `#wmeta\t<nickname>\t<colorHex>`.
    public func walletColor(_ nickname: String) -> String? {
        readLines().compactMap { line -> String? in
            guard line.hasPrefix("#wmeta\t") else { return nil }
            let p = line.components(separatedBy: "\t")
            guard p.count >= 3, p[1] == nickname, !p[2].isEmpty else { return nil }
            return p[2]
        }.first
    }

    public func setWalletColor(_ nickname: String, _ hex: String) {
        var lines = readLines().filter { line in
            guard line.hasPrefix("#wmeta\t") else { return true }
            let p = line.components(separatedBy: "\t")
            return !(p.count >= 2 && p[1] == nickname)
        }
        lines.append("#wmeta\t\(nickname)\t\(hex)")
        writeLines(lines)
    }

    /// Where a wallet module sits on the canvas, as `#wpos\t<nickname>\t<x>\t<y>`.
    /// Modules float wherever they're put rather than filling a grid, so the position is
    /// the user's arrangement and has to survive a relaunch.
    public func walletPosition(_ nickname: String) -> (x: Double, y: Double)? {
        readLines().compactMap { line -> (Double, Double)? in
            guard line.hasPrefix("#wpos\t") else { return nil }
            let p = line.components(separatedBy: "\t")
            guard p.count >= 4, p[1] == nickname,
                  let x = Double(p[2]), let y = Double(p[3]) else { return nil }
            return (x, y)
        }.first
    }

    public func setWalletPosition(_ nickname: String, x: Double, y: Double) {
        var lines = readLines().filter { line in
            guard line.hasPrefix("#wpos\t") else { return true }
            let p = line.components(separatedBy: "\t")
            return !(p.count >= 2 && p[1] == nickname)
        }
        lines.append("#wpos\t\(nickname)\t\(x)\t\(y)")
        writeLines(lines)
    }

    /// The order the wallet modules are arranged in, as `#worder\t<a,b,c>`. Names not in
    /// the list keep their natural position after the ones that are.
    public func walletOrder() -> [String] {
        readLines().compactMap { line -> [String]? in
            guard line.hasPrefix("#worder\t") else { return nil }
            let p = line.components(separatedBy: "\t")
            guard p.count >= 2 else { return nil }
            return p[1].components(separatedBy: ",").filter { !$0.isEmpty }
        }.first ?? []
    }

    public func setWalletOrder(_ names: [String]) {
        var lines = readLines().filter { !$0.hasPrefix("#worder\t") }
        lines.append("#worder\t" + names.joined(separator: ","))
        writeLines(lines)
    }

    // MARK: - Manual (non-EVM / staked) holdings

    /// Stored as `#manual\t<walletId>\t<symbol>\t<coingeckoId>\t<amount>` with three
    /// optional trailing fields `\t<network>\t<contract>\t<networkName>`. Entries written
    /// before network discovery existed have five fields and still load as coin-id holdings.
    public func manualHoldings() -> [ManualHolding] {
        readLines().compactMap { line in
            guard line.hasPrefix("#manual\t") else { return nil }
            let p = line.components(separatedBy: "\t")
            guard p.count >= 5,
                  let amt = Decimal(string: p[4], locale: Locale(identifier: "en_US_POSIX"))
            else { return nil }
            let cg = p[3].isEmpty ? nil : p[3]
            let network = p.count >= 7 && !p[5].isEmpty ? p[5] : nil
            let contract = p.count >= 7 && !p[6].isEmpty ? p[6] : nil
            let name = p.count >= 8 && !p[7].isEmpty
                ? p[7]
                : (network.map { TokenLocator.displayName(forNetwork: $0) } ?? "")
            return ManualHolding(walletId: p[1], symbol: p[2], amount: amt,
                                 network: network, contractAddress: contract,
                                 coingeckoId: cg, networkName: name)
        }
    }

    public func addManualHolding(_ m: ManualHolding) {
        // One entry per (wallet, symbol, NETWORK). The network has to be part of the key:
        // ETH on Base and ETH on Arbitrum are two different holdings, and keying on the
        // symbol alone made the second one overwrite the first.
        var lines = readLines().filter { line in
            guard line.hasPrefix("#manual\t") else { return true }
            let p = line.components(separatedBy: "\t")
            let network = p.count >= 8 ? p[7] : ""
            // Symbol matched case-insensitively: the same token can resolve to a
            // different spelling than the one on file (RETH today, rETH once the
            // contract's own casing is read), and a case-only difference must not
            // fork one holding into two rows. The new line carries the new spelling,
            // so re-adding a token also re-cases the row it lands on.
            return !(p.count >= 3 && p[1] == m.walletId
                     && p[2].caseInsensitiveCompare(m.symbol) == .orderedSame
                     && network == m.networkName)
        }
        let amtStr = NSDecimalNumber(decimal: m.amount)
            .description(withLocale: Locale(identifier: "en_US_POSIX"))
        let fields = ["#manual", m.walletId, m.symbol, m.coingeckoId ?? "", amtStr,
                      m.network ?? "", m.contractAddress ?? "", m.networkName]
        lines.append(fields.joined(separator: "\t"))
        writeLines(lines)
    }

    /// Remove one hand-entered holding. `network` nil removes every entry for the symbol
    /// — used when a whole wallet goes — while naming it removes just that one.
    public func removeManualHolding(walletId: String, symbol: String, network: String? = nil) {
        let updated = readLines().filter { line in
            guard line.hasPrefix("#manual\t") else { return true }
            let p = line.components(separatedBy: "\t")
            guard p.count >= 3, p[1] == walletId,
                  p[2].caseInsensitiveCompare(symbol) == .orderedSame else { return true }
            guard let network else { return false }        // no network named: drop them all
            return (p.count >= 8 ? p[7] : "") != network
        }
        writeLines(updated)
    }

    // MARK: - Private helpers

    private func readLines() -> [String] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n").filter { !$0.isEmpty }.map(Self.scrubbed)
    }

    /// Blank the retired address and scan-chain columns on any wallet line.
    ///
    /// Read and write both go through the line list, so doing this on read means the
    /// next write of any kind drops the address a previous build stored. Nothing scans
    /// any more, so an address on disk is a secret kept for no reason — and the columns
    /// stay present, empty, because `network` is the fourth field by position.
    static func scrubbed(_ line: String) -> String {
        guard !line.hasPrefix("#") else { return line }
        var parts = line.components(separatedBy: "\t")
        guard parts.count >= 3 else { return line }
        parts[1] = ""; parts[2] = ""
        return parts.joined(separator: "\t")
    }

    private func writeLines(_ lines: [String]) {
        let text = lines.joined(separator: "\n")
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
        // Owner read/write only — the file holds wallet addresses + API keys.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: fileURL.path)
    }

    private func parseWallet(from line: String) -> WalletSecret? {
        guard !line.hasPrefix("#") else { return nil }
        let parts = line.components(separatedBy: "\t")
        guard parts.count >= 3 else { return nil }          // parts[1], parts[2]: retired
        let network = parts.count >= 4 ? parts[3] : ""
        return WalletSecret(nickname: parts[0], network: network)
    }
}
