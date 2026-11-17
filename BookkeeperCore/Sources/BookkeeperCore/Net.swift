import Foundation

/// The one way Bookkeeper reaches the internet. Every price, chart, search and logo goes
/// through `Net.session`, so routing them all through Tor is one setting, not a dozen.
///
/// With a Tor port set, the session speaks SOCKS5 to Arti on 127.0.0.1 and nothing else:
/// before Arti is up, or if it dies, requests fail — they never fall back to a direct
/// connection. Host names travel inside the SOCKS request and are resolved at the Tor
/// exit, so no lookup leaves this Mac either.
public enum Net {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var port: Int?
    nonisolated(unsafe) private static var cached: (port: Int?, session: URLSession)?

    /// The local SOCKS port Arti listens on, or nil for direct connections.
    public static var torPort: Int? {
        get { lock.withLock { port } }
        set { lock.withLock { port = newValue } }
    }

    /// True while requests go through Tor.
    public static var throughTor: Bool { torPort != nil }

    /// Tor circuits are slower than a direct line; a request gets longer before it gives up.
    public static var timeout: TimeInterval { throughTor ? 45 : 20 }

    public static var session: URLSession {
        lock.withLock {
            if let c = cached, c.port == port { return c.session }
            let s = make(port: port)
            cached = (port, s)
            return s
        }
    }

    /// A session for `port`: SOCKS5 to 127.0.0.1 with every other proxy off, or plain.
    public static func make(port: Int?) -> URLSession {
        let config = URLSessionConfiguration.default
        if let port {
            config.connectionProxyDictionary = [
                kCFNetworkProxiesSOCKSEnable as String: 1,
                kCFNetworkProxiesSOCKSProxy as String: "127.0.0.1",
                kCFNetworkProxiesSOCKSPort as String: port,
                kCFStreamPropertySOCKSVersion as String: kCFStreamSocketSOCKSVersion5 as String,
                kCFNetworkProxiesHTTPEnable as String: 0,
                kCFNetworkProxiesHTTPSEnable as String: 0,
                kCFNetworkProxiesProxyAutoConfigEnable as String: 0,
                kCFNetworkProxiesProxyAutoDiscoveryEnable as String: 0,
            ]
            config.waitsForConnectivity = false
        }
        return URLSession(configuration: config)
    }
}
