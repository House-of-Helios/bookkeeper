import SwiftUI
import BookkeeperCore

/// Downloads token logos and caches them to disk. The cache persists across launches.
///
/// The URL is derived from the contract address (`TokenIcon`), not looked up — so this
/// spends no API budget and needs no throttle. Downloads run concurrently and a whole
/// wallet's logos land in about as long as one image takes. The old path asked a
/// rate-limited JSON API for each image URL and had to sleep 2.5s between tokens; a
/// 30-token wallet waited over a minute and usually 429'd before the end of the list.
@Observable @MainActor
final class IconCache {
    static let shared = IconCache()

    private(set) var files: [String: URL] = [:]   // key -> local image on disk
    /// The one remaining lookup: non-EVM coins (XMR, SC) have no contract to derive a
    /// URL from. A wallet holds a couple of these, so it never threatens the rate limit.
    private let coinGecko = CoinGeckoIconService(auth: CoinGeckoAuth(key: { SecretStore().apiKey("coingecko") }))
    private let dir: URL
    private var inFlight = Set<String>()
    /// Keys the CDN has already answered 404 for — don't ask again this session.
    private var missing = Set<String>()
    /// Keys whose fetch failed to reach anything (offline, a Tor route dropping, CoinGecko
    /// busy) — tried again after this moment, never written off as having no logo.
    private var retryAt: [String: Date] = [:]
    @ObservationIgnored private var retryScheduled = false
    private static let retryEvery: TimeInterval = 45
    /// Colours picked by hand in the colour drawer, keyed like `files` — they win over the
    /// logo's own. Kept beside the icons, in `colors.json`, so icons and their colours
    /// live in one place.
    private(set) var picked: [String: String] = [:]
    private var pickedFile: URL { dir.appendingPathComponent("colors.json") }

    /// Memoized dominant colors, keyed like `files`. Not observed — decoded lazily on
    /// first request so colour-coding never re-decodes an icon per render.
    @ObservationIgnored private var colorCache: [String: ColorExtract.RGB] = [:]
    /// Decoded images, held once. Views were calling `NSImage(contentsOf:)` inside
    /// `body`, so every render read the PNG off disk again — during a continuous hover
    /// that is once per mouse move, and the freshly built image views cross-faded
    /// against each other, which is what strobed.
    @ObservationIgnored private var decoded: [String: NSImage] = [:]

    /// How many logos download at once. Plain CDN image GETs, so this is bounded by
    /// politeness and sockets rather than by any request budget.
    private static let concurrency = 8

    init() {
        dir = DataRoot.url.appendingPathComponent("icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in items where f.pathExtension == "png" {
                // Never during `--snapshot`, which only ever reads.
                let writes = SnapshotRenderer.requestedDirectory == nil
                if Self.isSuperseded(f.deletingPathExtension().lastPathComponent) {
                    if writes { try? FileManager.default.removeItem(at: f) }
                    continue
                }
                // Icons saved before every one was made the same: made the same now, once.
                if writes { Self.standardiseInPlace(f) }
                files[f.deletingPathExtension().lastPathComponent] = f
            }
        }
        // Faces the app ships win over downloads under the same key (`Resources/Icons`,
        // 128-px discs named by key): Ethereum's coloured prism, Base's blue disc.
        if let shipped = Bundle.main.url(forResource: "Icons", withExtension: nil),
           let items = try? FileManager.default.contentsOfDirectory(at: shipped, includingPropertiesForKeys: nil) {
            for f in items where f.pathExtension == "png" { files[f.deletingPathExtension().lastPathComponent] = f }
        }
        picked = (try? Data(contentsOf: pickedFile))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    /// A logo saved under its contract before that contract was filed under its coin id
    /// (`canonical`) is never read again — the coin-id file is — so it goes.
    private static func isSuperseded(_ key: String) -> Bool {
        guard let ca = key.split(separator: "_").last.map(String.init), ca.hasPrefix("0x") else { return false }
        return canonical[ca.lowercased()] != nil
    }

    /// Pick a colour for an icon key (a token's or a network's), or nil to go back to the
    /// logo's own.
    func pick(_ hex: String?, forKey key: String) {
        picked[key] = hex
        if let data = try? JSONEncoder().encode(picked) { try? data.write(to: pickedFile, options: .atomic) }
    }

    nonisolated static func rgb(hex: String) -> ColorExtract.RGB {
        var v: UInt64 = 0
        Scanner(string: hex.hasPrefix("#") ? String(hex.dropFirst()) : hex).scanHexInt64(&v)
        return ColorExtract.RGB(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255)
    }

    // MARK: - One size, one format

    /// Every icon is stored as a 128 × 128 PNG, the logo fitted and centred on a clear
    /// square. Sources send anything — 250-px PNGs and JPEGs from CoinGecko, 64-px WebPs
    /// from the contract CDN — and 128 is sharp at the largest size the app draws one
    /// (a ring's centre on a Retina screen) while keeping each file a few kilobytes.
    static let side = 128

    /// The download as a standard icon, or nil if it isn't an image at all. A logo that
    /// isn't a filled disc — a bare mark on clear (Uniswap's unicorn, a grey prism) — is
    /// set on a white disc, so every logo reads as a coin, the way BOLD, HYPE and VVV do.
    nonisolated static func standardised(_ data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let fitted = draw(image, scale: 1, onDisc: false) else { return nil }
        let out = isDisc(fitted) ? fitted : (draw(image, scale: 0.68, onDisc: true) ?? fitted)
        return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
    }

    /// The image fitted and centred on the standard square at `scale`, over a white disc
    /// filling the square when `onDisc`.
    private nonisolated static func draw(_ image: CGImage, scale k: CGFloat, onDisc: Bool) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let w = CGFloat(image.width), h = CGFloat(image.height), s = CGFloat(side)
        if onDisc {
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: s, height: s))
        }
        let scale = min(s / w, s / h) * k
        let rect = CGRect(x: (s - w * scale) / 2, y: (s - h * scale) / 2, width: w * scale, height: h * scale)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }

    /// Whether a standard icon is a filled disc (or square): solid all round a ring just
    /// inside its edge, where a bare mark on clear shows through.
    private nonisolated static func isDisc(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return true }
        let s = Double(side), r = s * 0.40, n = 48
        var solid = 0
        for i in 0..<n {
            let a = Double(i) / Double(n) * .pi * 2
            let x = Int(s / 2 + r * cos(a)), y = Int(s / 2 + r * sin(a))
            if p[y * image.bytesPerRow + x * 4 + 3] > 200 { solid += 1 }
        }
        return solid >= n * 9 / 10
    }

    /// Re-save a stored icon in the standard form, if it isn't already.
    private static func standardiseInPlace(_ url: URL) {
        guard let data = try? Data(contentsOf: url),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return }
        let w = props[kCGImagePropertyPixelWidth] as? Int, h = props[kCGImagePropertyPixelHeight] as? Int
        let isPNG = (CGImageSourceGetType(src) as String?) == "public.png"
        let disc = CGImageSourceCreateImageAtIndex(src, 0, nil).map(isDisc) ?? true
        guard !(isPNG && w == side && h == side && disc), let fixed = standardised(data) else { return }
        try? fixed.write(to: url, options: .atomic)
    }

    /// Cache key for a token's logo — by CoinGecko id wherever one is known, otherwise
    /// by contract.
    ///
    /// The id comes first deliberately. The two sources disagree about the same asset:
    /// the contract CDN serves a snapshot taken against an address, so a rebranded token
    /// keeps its old logo there indefinitely, while the coin register tracks the rebrand.
    /// Keying by contract meant the same token entered two ways — pasted address vs typed
    /// ticker — cached under two keys and showed two different logos side by side. One
    /// key per asset is what makes them agree.
    nonisolated static func key(for token: Token) -> String? {
        if let cg = coinId(for: token) { return "cg_\(cg)" }
        if let chain = token.chain, let ca = token.contractAddress {
            return "\(chain.rawValue)_\(ca.lowercased())"
        }
        return nil
    }

    /// The coin id a token's logo is filed under: its own, else — for a chain's native coin
    /// scanned with no id (ETH on Arbitrum) — the coin its symbol names. So every ETH, by
    /// whatever route it arrived, shows the one ETH logo.
    nonisolated static func coinId(for token: Token) -> String? {
        if let cg = token.coingeckoId { return cg }
        // A well-known token is one icon whatever chain it sits on — USDC on HyperEVM is
        // USDC on Ethereum — but only at its real contract: matched by address, never by
        // symbol, so a look-alike calling itself USDC never borrows USDC's face.
        if let ca = token.contractAddress?.lowercased(), let id = canonical[ca] { return id }
        guard token.contractAddress == nil || token.contractAddress == "native" else { return nil }
        return NetworkTint.coinId(forSymbol: token.symbol)
    }

    /// Real deployments of tokens that live on many chains, by contract address → coin id.
    private nonisolated static let canonical: [String: String] = [
        // USDC — Ethereum, Arbitrum, Base, HyperEVM
        "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48": "usd-coin",
        "0xaf88d065e77c8cc2239327c5edb3a432268e5831": "usd-coin",
        "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913": "usd-coin",
        "0xb88339cb7199b77e23db6e890353e22632ba630f": "usd-coin",
        // USDT — Ethereum, Arbitrum
        "0xdac17f958d2ee523a2206206994597c13d831ec7": "tether",
        "0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9": "tether",
        // DAI, WBTC, LINK, UNI, AAVE, rETH — Ethereum
        "0x6b175474e89094c44da98b954eedeac495271d0f": "dai",
        "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599": "wrapped-bitcoin",
        "0x514910771af9ca656af840dff83e8264ecf986ca": "chainlink",
        "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984": "uniswap",
        "0x7fc66500c84a76ad7e9c93437bfc5ac33e2ddae9": "aave",
        "0xae78736cd615f374d3085123a210448e74fc6393": "rocket-pool-eth",
        // WETH — Ethereum, Arbitrum, Base
        "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2": "weth",
        "0x82af49447d8a07e3bd95bd0d56f35241523fbab1": "weth",
        "0x4200000000000000000000000000000000000006": "weth",
    ]
    /// Local file URL for a token's logo if already cached.
    func url(for token: Token) -> URL? {
        guard let k = Self.key(for: token) else { return nil }
        return files[k]
    }

    /// The token's logo, decoded once and kept. Every view should use this rather than
    /// building an NSImage from the URL itself.
    func image(for token: Token) -> NSImage? {
        guard let k = Self.key(for: token) else { return nil }
        if let img = decoded[k] { return img }
        guard let f = files[k], let img = NSImage(contentsOf: f) else { return nil }
        decoded[k] = img
        return img
    }

    /// Dominant brand color of the logo a token displays (memoized) — the downloaded one,
    /// the only source of icons in the app.
    func tintRGB(for token: Token) -> ColorExtract.RGB? {
        if let k = Self.key(for: token), let hex = picked[k] { return Self.rgb(hex: hex) }
        if let k = Self.key(for: token), let f = files[k] {
            if let c = colorCache[k] { return c }
            if let img = NSImage(contentsOf: f), let rgb = ColorExtract.dominantRGB(of: img) {
                colorCache[k] = rgb; return rgb
            }
        }
        return nil
    }

    /// Brand color as a SwiftUI Color, or nil if no logo cached.
    func tint(for token: Token) -> Color? {
        tintRGB(for: token).map { Color(.sRGB, red: $0.r, green: $0.g, blue: $0.b, opacity: 1) }
    }

    // MARK: - Network logos, for a network with no token of its own (Base)

    /// The one network logo source: DefiLlama's keyless chain icons, stored here beside the
    /// token icons as `net_<slug>.png`, standardised the same way.
    nonisolated static func networkKey(_ n: Network) -> String {
        "net_" + n.name.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    private nonisolated static func networkURL(_ n: Network) -> URL? {
        let slug = ["Base": "base", "zkSync": "zksync-era", "BNB Chain": "bsc"][n.name]
            ?? n.name.lowercased().replacingOccurrences(of: " ", with: "-")
        return URL(string: "https://icons.llamao.fi/icons/chains/rsz_\(slug).jpg")
    }

    func image(forNetwork n: Network) -> NSImage? {
        let k = Self.networkKey(n)
        if let img = decoded[k] { return img }
        guard let f = files[k], let img = NSImage(contentsOf: f) else { return nil }
        decoded[k] = img
        return img
    }

    func tintRGB(forNetwork n: Network) -> ColorExtract.RGB? {
        let k = Self.networkKey(n)
        if let hex = picked[k] { return Self.rgb(hex: hex) }
        if let c = colorCache[k] { return c }
        guard let img = image(forNetwork: n), let c = ColorExtract.dominantRGB(of: img) else { return nil }
        colorCache[k] = c
        return c
    }

    /// Fetch the logos of these networks not yet stored (a few at most).
    func prefetchNetworks(_ networks: [Network]) async {
        for n in networks {
            let k = Self.networkKey(n)
            guard files[k] == nil, !inFlight.contains(k), !missing.contains(k),
                  (retryAt[k] ?? .distantPast) <= Date(), let url = Self.networkURL(n) else { continue }
            inFlight.insert(k)
            defer { inFlight.remove(k) }
            guard let (data, response) = try? await Net.session.data(from: url) else {
                retryAt[k] = Date().addingTimeInterval(Self.retryEvery)
                continue
            }
            guard (response as? HTTPURLResponse)?.statusCode == 200, let icon = Self.standardised(data) else {
                missing.insert(k)
                continue
            }
            let dest = dir.appendingPathComponent("\(k).png")
            try? icon.write(to: dest, options: .atomic)
            files[k] = dest
            retryAt[k] = nil
        }
    }

    /// Whether this token's logo is still on its way — fetching now, or waiting to retry.
    /// The lettered disc shows a turning ring meanwhile, so a missing logo reads as
    /// "coming", not "none".
    func isLoading(_ token: Token) -> Bool {
        guard let k = Self.key(for: token), files[k] == nil, !missing.contains(k) else { return false }
        return inFlight.contains(k) || retryAt[k] != nil
    }

    /// Download any logos these tokens don't already have, `concurrency` at a time.
    func prefetch(_ tokens: [Token]) async {
        let now = Date()
        let wanted = tokens.compactMap { token -> (key: String, token: Token)? in
            guard let k = Self.key(for: token),
                  files[k] == nil, !inFlight.contains(k), !missing.contains(k),
                  (retryAt[k] ?? .distantPast) <= now else { return nil }
            return (k, token)
        }
        guard !wanted.isEmpty else { return }
        for (k, _) in wanted { inFlight.insert(k) }

        await withTaskGroup(of: (String, Data?, Bool).self) { group in
            var next = wanted.makeIterator()
            var running = 0

            func start() {
                guard let item = next.next() else { return }
                running += 1
                group.addTask { [coinGecko] in
                    // Sources in the order the key prefers them: the register's image for
                    // anything with a coin id, the contract CDN otherwise — and the CDN
                    // again as a fallback, so a token still gets its logo when CoinGecko
                    // is rate-limited or unreachable.
                    // `answered` stays true only if every place asked gave an answer — so a
                    // nil at the end means "no logo exists", not "couldn't ask".
                    var sources: [URL] = []
                    var answered = true
                    if let cg = Self.coinId(for: item.token) {
                        if let url = await coinGecko.iconURL(coingeckoId: cg) { sources.append(url) } else { answered = false }
                    }
                    if let url = TokenIcon.url(for: item.token) { sources.append(url) }

                    for source in sources {
                        guard let (data, response) = try? await Net.session.data(from: source) else {
                            answered = false
                            continue
                        }
                        guard let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty
                        else {
                            if (response as? HTTPURLResponse)?.statusCode == 429 { answered = false }
                            continue
                        }
                        return (item.key, data, true)
                    }
                    return (item.key, nil, answered)
                }
            }

            for _ in 0..<Self.concurrency { start() }
            for await (key, data, answered) in group {
                running -= 1
                if let data, let icon = Self.standardised(data) {
                    let dest = dir.appendingPathComponent("\(key).png")
                    try? icon.write(to: dest, options: .atomic)
                    files[key] = dest
                    retryAt[key] = nil
                } else if answered {
                    // Every source answered and none has a logo (spam tokens mostly) —
                    // stop asking, and let the row show its lettered disc.
                    missing.insert(key)
                    retryAt[key] = nil
                } else {
                    // Couldn't ask — try again shortly rather than giving up for the session.
                    retryAt[key] = Date().addingTimeInterval(Self.retryEvery)
                }
                inFlight.remove(key)
                start()
            }
            _ = running
        }
        scheduleRetry(tokens)
    }

    /// One pending pass at a time: when the earliest retry comes due, prefetch again.
    private func scheduleRetry(_ tokens: [Token]) {
        guard !retryScheduled, let due = retryAt.values.min() else { return }
        retryScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(1, due.timeIntervalSinceNow) + 1))
            retryScheduled = false
            await prefetch(tokens)
        }
    }
}
