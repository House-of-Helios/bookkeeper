import Foundation

public enum Chain: String, CaseIterable, Codable, Sendable {
    case ethereum
    case arbitrum
    case base

    /// Single-letter network badge shown left of a holding row (ref image 02).
    public var badge: String {
        switch self {
        case .ethereum: return "E"
        case .arbitrum: return "A"
        case .base:     return "B"
        }
    }

    public var displayName: String {
        switch self {
        case .ethereum: return "Ethereum"
        case .arbitrum: return "Arbitrum"
        case .base:     return "Base"
        }
    }
}
