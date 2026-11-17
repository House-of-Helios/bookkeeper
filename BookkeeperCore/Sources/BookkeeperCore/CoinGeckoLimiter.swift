import Foundation

/// One global pacer for ALL CoinGecko calls — a token bucket, not a flat queue. The demo key
/// allows ~30 req/min TOTAL, so a naive 2.4s serial gate made interactive calls (a token
/// modal's 2 requests) wait behind every background call. A bucket fixes that: a small burst
/// fires immediately (so opening a token is snappy) and only sustained bulk work — the P&L /
/// history gather — drains the bucket and gets paced to the refill rate.
public actor CoinGeckoLimiter {
    public static let shared = CoinGeckoLimiter()

    private let capacity: Double        // burst size
    private let refillPerSec: Double    // tokens added per second
    private var tokens: Double
    private var last: Date

    public init(capacity: Double = 8, perMinute: Double = 25) {
        self.capacity = capacity
        self.refillPerSec = perMinute / 60
        self.tokens = capacity
        self.last = Date()
    }

    /// Consume one token, waiting only if the bucket is empty (i.e. under sustained load).
    public func pace() async {
        refill()
        if tokens >= 1 { tokens -= 1; return }
        let waitSec = (1 - tokens) / refillPerSec
        try? await Task.sleep(nanoseconds: UInt64(waitSec * 1_000_000_000))
        refill()
        tokens = max(0, tokens - 1)
    }

    private func refill() {
        let now = Date()
        tokens = min(capacity, tokens + now.timeIntervalSince(last) * refillPerSec)
        last = now
    }
}
